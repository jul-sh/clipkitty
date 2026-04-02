use clap::Parser;
use purr::{
    benchmark_fixture::{default_synthetic_bench_db_path, ensure_synthetic_benchmark_fixture},
    inspect_store_bootstrap, ClipboardStore, ClipboardStoreApi, StoreBootstrapPlan,
};
use std::path::PathBuf;
use std::time::Instant;

#[derive(Parser, Debug)]
struct Args {
    #[arg(long)]
    db: Option<PathBuf>,
    #[arg(long, default_value_t = 10)]
    warmup: usize,
    #[arg(long, default_value_t = 100)]
    iterations: usize,
    #[arg(long = "query")]
    queries: Vec<String>,
    #[arg(long, default_value_t = false)]
    rebuild_fixture: bool,
}

const DEFAULT_QUERIES: [&str; 6] = [
    "function",
    "error",
    "class",
    "functoin",
    "error return",
    "lorem ipsum",
];

fn percentile(sorted: &[u128], numerator: usize, denominator: usize) -> u128 {
    let index = ((sorted.len().saturating_sub(1)) * numerator) / denominator;
    sorted[index]
}

fn open_store_with_ready_index(db_path: &PathBuf) -> ClipboardStore {
    let db_path_string = db_path.to_string_lossy().to_string();
    let needs_rebuild = matches!(
        inspect_store_bootstrap(db_path_string.clone()).expect("failed to inspect store bootstrap"),
        StoreBootstrapPlan::RebuildIndex { .. }
    );
    let store = ClipboardStore::new(db_path_string).expect("failed to open benchmark store");
    if needs_rebuild {
        eprintln!("Rebuilding search index for {}", db_path.display());
        store
            .rebuild_index()
            .expect("failed to rebuild benchmark index");
    }
    store
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let args = Args::parse();
    let db_path = args.db.unwrap_or_else(default_synthetic_bench_db_path);
    let generated = ensure_synthetic_benchmark_fixture(&db_path, args.rebuild_fixture)
        .expect("failed to prepare synthetic benchmark fixture");

    let store = open_store_with_ready_index(&db_path);
    let queries: Vec<String> = if args.queries.is_empty() {
        DEFAULT_QUERIES
            .iter()
            .map(|query| query.to_string())
            .collect()
    } else {
        args.queries.clone()
    };

    println!(
        "Benchmarking {} queries on {}",
        queries.len(),
        db_path.display()
    );
    println!(
        "Synthetic fixture: {} items, {:.2} MB text",
        generated.total_items,
        generated.total_text_bytes as f64 / 1024.0 / 1024.0
    );
    println!(
        "Warmup iterations: {}, measured iterations: {}",
        args.warmup, args.iterations
    );

    for query in &queries {
        for _ in 0..args.warmup {
            let _ = store
                .search(query.clone(), purr::ListPresentationProfile::CompactRow)
                .await
                .expect("warmup search failed");
        }

        let mut samples_us = Vec::with_capacity(args.iterations);
        let mut result_count = 0u64;
        for _ in 0..args.iterations {
            let start = Instant::now();
            let result = store
                .search(query.clone(), purr::ListPresentationProfile::CompactRow)
                .await
                .expect("benchmark search failed");
            let elapsed = start.elapsed().as_micros();
            result_count = result.total_count;
            samples_us.push(elapsed);
        }

        samples_us.sort_unstable();
        let sum: u128 = samples_us.iter().copied().sum();
        let mean = sum as f64 / samples_us.len() as f64;
        let min = *samples_us.first().unwrap_or(&0);
        let max = *samples_us.last().unwrap_or(&0);
        let p50 = percentile(&samples_us, 1, 2);
        let p95 = percentile(&samples_us, 95, 100);
        let p99 = percentile(&samples_us, 99, 100);

        println!();
        println!("query: {query}");
        println!("results: {result_count}");
        println!("min_us: {min}");
        println!("p50_us: {p50}");
        println!("p95_us: {p95}");
        println!("p99_us: {p99}");
        println!("max_us: {max}");
        println!("mean_us: {:.1}", mean);
    }
}
