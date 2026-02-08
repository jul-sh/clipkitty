//! Trace performance: instrument each stage of the search pipeline.

use clipkitty_core::{ClipboardStore, ClipboardStoreApi};

const BENCH_DB: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/benches/synthetic_1m.sqlite");

fn size_label(n: usize) -> String {
    if n >= 1_000_000 { format!("{}M", n / 1_000_000) }
    else if n >= 1_000 { format!("{}k", n / 1_000) }
    else { n.to_string() }
}

fn build_store(n: usize) -> (ClipboardStore, tempfile::TempDir) {
    let tmp = tempfile::TempDir::new().unwrap();
    let db_path = tmp.path().join("bench.sqlite");
    if n >= 1_000_000 {
        std::fs::copy(BENCH_DB, &db_path).unwrap();
    } else {
        // Create with proper schema (PRIMARY KEY on id) then INSERT rows.
        // CREATE TABLE AS SELECT would strip the PRIMARY KEY, causing full table scans.
        let conn = rusqlite::Connection::open(&db_path).unwrap();
        conn.execute_batch(&format!(
            "ATTACH DATABASE '{}' AS source;
             CREATE TABLE items (
                 id INTEGER PRIMARY KEY AUTOINCREMENT,
                 content TEXT NOT NULL,
                 contentHash TEXT NOT NULL,
                 timestamp DATETIME NOT NULL,
                 sourceApp TEXT,
                 contentType TEXT DEFAULT 'text',
                 imageData BLOB,
                 linkTitle TEXT,
                 linkImageData BLOB,
                 sourceAppBundleID TEXT,
                 linkDescription TEXT,
                 thumbnail BLOB,
                 colorRgba INTEGER
             );
             INSERT INTO items SELECT * FROM source.items WHERE id <= {};
             DETACH DATABASE source;",
            BENCH_DB, n
        )).unwrap();
    }
    let store = ClipboardStore::new(db_path.to_string_lossy().to_string()).unwrap();
    (store, tmp)
}

fn main() {
    let rt = tokio::runtime::Runtime::new().unwrap();

    let queries: &[&str] = &["function", "git commit message", "xyzzyplugh"];
    let sizes: &[usize] = &[1_000, 10_000, 50_000, 100_000, 500_000];

    // ── Empty query (initial screen) ────────────────────────────────
    println!("=== INITIAL SCREEN (empty query, median of 5 runs) ===");
    println!("{:<25} {:>6} {:>10}", "query", "size", "total");
    println!("{}", "-".repeat(45));

    for &size in sizes {
        let (store, _tmp) = build_store(size);

        // Warmup
        for _ in 0..2 {
            let _ = rt.block_on(store.search("".to_string()));
        }

        let mut durations = Vec::with_capacity(5);
        for _ in 0..5 {
            let t0 = std::time::Instant::now();
            let _ = rt.block_on(store.search("".to_string())).unwrap();
            durations.push(t0.elapsed().as_secs_f64() * 1000.0);
        }
        durations.sort_by(|a, b| a.partial_cmp(b).unwrap());

        println!(
            "{:<25} {:>6} {:>9.2}ms",
            "(empty)", size_label(size), durations[2],
        );
    }
    println!();

    // ── Search queries (instrumented pipeline breakdown) ────────────
    println!("=== PIPELINE BREAKDOWN (median of 5 runs, proper PRIMARY KEY) ===");
    println!("{:<25} {:>6} {:>7} {:>10} {:>10} {:>10} {:>10} {:>10}",
        "query", "size", "cands", "tantivy", "highlight", "db_fetch", "match_gen", "total");
    println!("{}", "-".repeat(96));

    for &query in queries {
        for &size in sizes {
            let (store, _tmp) = build_store(size);

            // Warmup
            for _ in 0..2 {
                let _ = rt.block_on(store.search(query.to_string()));
            }

            let mut timings = Vec::with_capacity(5);
            for _ in 0..5 {
                let t = rt.block_on(store.search_instrumented(query.to_string())).unwrap();
                timings.push(t);
            }

            timings.sort_by(|a, b| a.total_ms.partial_cmp(&b.total_ms).unwrap());
            let m = &timings[2];

            println!(
                "{:<25} {:>6} {:>7} {:>9.2}ms {:>9.2}ms {:>9.2}ms {:>9.2}ms {:>9.2}ms",
                query, size_label(size), m.num_candidates,
                m.tantivy_ms, m.highlight_ms, m.db_fetch_ms, m.match_gen_ms, m.total_ms,
            );
        }
        println!();
    }
}
