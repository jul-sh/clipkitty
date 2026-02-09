//! Benchmark: search latency vs database size.
//!
//! Uses a pre-built 1M-item SQLite database (benches/synthetic_1m.sqlite).
//! For each query × size combination, builds a store and benchmarks search.
//!
//! Generate the data file: cargo run --release --bin generate-bench-data

use criterion::{BenchmarkId, Criterion, Throughput, criterion_group, criterion_main};
use clipkitty_core::{ClipboardStore, ClipboardStoreApi};

const QUERIES: &[(&str, &str)] = &[
    ("empty",      ""),
    ("trigram",    "function"),
    ("short",      "fn"),
    ("phrase",     "git commit message"),
    ("no_results", "xyzzyplugh"),
];

const DB_SIZES: &[usize] = &[1_000, 10_000, 50_000, 100_000, 500_000, 1_000_000];

const BENCH_DB: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/benches/synthetic_1m.sqlite"
);

/// Human-readable size label: 1_000 → "1k", 1_000_000 → "1M", etc.
fn size_label(n: usize) -> String {
    if n >= 1_000_000 && n % 1_000_000 == 0 {
        format!("{}M", n / 1_000_000)
    } else if n >= 1_000 && n % 1_000 == 0 {
        format!("{}k", n / 1_000)
    } else {
        n.to_string()
    }
}

/// Build a store with `n` items from the pre-built database.
///
/// For the full 1M database, copies the file directly.
/// For smaller sizes, creates a fresh DB and copies only the needed rows
/// via ATTACH — much faster than copying 530MB then deleting.
fn build_store(n: usize) -> (ClipboardStore, tempfile::TempDir) {
    let tmp = tempfile::TempDir::new().unwrap();
    let db_path = tmp.path().join("bench.sqlite");

    if n >= 1_000_000 {
        std::fs::copy(BENCH_DB, &db_path)
            .expect("Missing benches/synthetic_1m.sqlite — run: cargo run --release --bin generate-bench-data");
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

fn bench_search(c: &mut Criterion) {
    let rt = tokio::runtime::Runtime::new().unwrap();

    for &(_label, query) in QUERIES {
        let mut group = c.benchmark_group(format!("search(\"{}\")", query));
        group.throughput(Throughput::Elements(1));

        for &size in DB_SIZES {
            if size >= 50_000 {
                group.sample_size(10);
            }

            let (store, _tmp) = build_store(size);
            let label = size_label(size);

            group.bench_with_input(BenchmarkId::from_parameter(&label), &size, |b, _| {
                b.iter(|| {
                    rt.block_on(store.search(query.to_string())).unwrap();
                });
            });
        }

        group.finish();
    }
}

criterion_group!(benches, bench_search);
criterion_main!(benches);
