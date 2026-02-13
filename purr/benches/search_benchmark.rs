use criterion::{criterion_group, criterion_main, Criterion};
use purr::ClipboardStore;
use purr::ClipboardStoreApi;

fn setup_store() -> ClipboardStore {
    // Use the synthetic 1M database for realistic benchmarks
    let db_path = concat!(env!("CARGO_MANIFEST_DIR"), "/benches/synthetic_1m.sqlite");
    ClipboardStore::new(db_path.to_string()).expect("Failed to open synthetic database")
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
                    store.search(query.to_string()).await.unwrap()
                })
            });
        });
    }
    group.finish();
}

criterion_group!(benches, bench_search);
criterion_main!(benches);
