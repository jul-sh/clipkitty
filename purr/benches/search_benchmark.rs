use criterion::{criterion_group, criterion_main, Criterion};
use purr::ClipboardStore;
use purr::ClipboardStoreApi;
use rand::seq::SliceRandom;
use rand::rngs::StdRng;
use rand::SeedableRng;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::PathBuf;

const TARGET_COUNT: usize = 1_000_000;
const SEED: u64 = 42;
const BATCH_SIZE: usize = 50_000;

fn bench_db_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("benches/synthetic_1m.sqlite")
}

fn source_db_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../SyntheticData.sqlite")
}

fn hash_string(s: &str) -> String {
    let mut hasher = DefaultHasher::new();
    s.hash(&mut hasher);
    hasher.finish().to_string()
}

/// Generate the 1M-item benchmark database from the SyntheticData corpus.
/// Reads text content, shuffles words with a seeded RNG, and writes 1M items.
fn generate_bench_db(out_path: &std::path::Path) {
    let source_path = source_db_path();
    assert!(
        source_path.exists(),
        "Corpus database not found at {}. Run the data generator first.",
        source_path.display()
    );

    eprintln!("Generating benchmark database ({} items)...", TARGET_COUNT);

    let source = rusqlite::Connection::open_with_flags(
        &source_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .expect("Failed to open SyntheticData.sqlite");

    let mut stmt = source
        .prepare("SELECT content FROM items WHERE contentType = 'text'")
        .unwrap();
    let corpus: Vec<String> = stmt
        .query_map([], |row| row.get::<_, String>(0))
        .unwrap()
        .filter_map(|r| r.ok())
        .filter(|s| !s.trim().is_empty())
        .collect();

    eprintln!("  Loaded {} corpus items", corpus.len());

    if out_path.exists() {
        std::fs::remove_file(out_path).unwrap();
    }

    // Use ClipboardStore to create the schema so it stays in sync with the app.
    // Drop it immediately — we reopen with raw rusqlite for fast bulk inserts.
    {
        let store = ClipboardStore::new(out_path.to_str().unwrap().to_string())
            .expect("Failed to create benchmark database");
        drop(store);
    }
    // Clean up the tantivy index created as a side-effect; only the sqlite file is needed.
    let tantivy_dir = out_path.parent().unwrap().join("tantivy_index_v3");
    if tantivy_dir.exists() {
        std::fs::remove_dir_all(&tantivy_dir).ok();
    }

    let out = rusqlite::Connection::open(out_path).unwrap();
    out.execute_batch("PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF;")
        .unwrap();

    let mut rng = StdRng::seed_from_u64(SEED);
    let base_ts = 1700000000i64;

    for batch_start in (0..TARGET_COUNT).step_by(BATCH_SIZE) {
        let batch_end = (batch_start + BATCH_SIZE).min(TARGET_COUNT);
        out.execute_batch("BEGIN").unwrap();

        for i in batch_start..batch_end {
            let base_text = &corpus[i % corpus.len()];
            let mut words: Vec<&str> = base_text.split_whitespace().collect();
            words.shuffle(&mut rng);
            let content = format!("{} #{}", words.join(" "), i);
            let content_hash = hash_string(&content);
            let ts = base_ts + (TARGET_COUNT - i) as i64;
            let timestamp = format!(
                "2023-11-{:02} {:02}:{:02}:{:02}.000",
                ((ts / 86400) % 28) + 1,
                (ts / 3600) % 24,
                (ts / 60) % 60,
                ts % 60,
            );

            out.execute(
                "INSERT INTO items (content, contentHash, timestamp, contentType) VALUES (?1, ?2, ?3, 'text')",
                rusqlite::params![content, content_hash, timestamp],
            )
            .unwrap();
        }

        out.execute_batch("COMMIT").unwrap();
        eprintln!("  {} / {}", batch_end, TARGET_COUNT);
    }

    let size = std::fs::metadata(out_path).unwrap().len();
    eprintln!(
        "  Done: {} items -> {} ({:.0} MB)",
        TARGET_COUNT,
        out_path.display(),
        size as f64 / 1_048_576.0
    );
}

fn setup_store() -> ClipboardStore {
    let db_path = bench_db_path();
    if !db_path.exists() {
        generate_bench_db(&db_path);
    }
    ClipboardStore::new(db_path.to_str().unwrap().to_string())
        .expect("Failed to open synthetic database")
}

fn bench_search(c: &mut Criterion) {
    let store = setup_store();
    let rt = tokio::runtime::Runtime::new().unwrap();

    let queries = vec![
        ("short_2char", "hi"),
        ("medium_word", "hello"),
        ("long_word", "riverside"),
        ("multi_word", "hello world"),
        ("fuzzy_typo", "riversde"),
        ("trailing_space", "hello "),
        ("long_query", "error build failed due to dependency"),
    ];

    let mut group = c.benchmark_group("search");
    group.sample_size(20);

    for (name, query) in queries {
        group.bench_function(name, |b| {
            b.iter(|| {
                rt.block_on(async {
                    store.search(query.to_string(), 400).await.unwrap()
                })
            });
        });
    }
    group.finish();
}

criterion_group!(benches, bench_search);
criterion_main!(benches);
