//! Generate the synthetic benchmark database used by `run_search_bench`.
//!
//! Usage:
//!     cargo run --release --bin generate-perf-db
//!     cargo run --release --bin generate-perf-db -- --output /tmp/bench.sqlite

use clap::Parser;
use purr::benchmark_fixture::{default_synthetic_bench_db_path, ensure_synthetic_benchmark_fixture};
use std::path::PathBuf;

#[derive(Parser, Debug)]
struct Args {
    #[arg(long)]
    output: Option<PathBuf>,
    #[arg(long, default_value_t = false)]
    force: bool,
}

fn main() {
    let args = Args::parse();
    let output = args.output.unwrap_or_else(default_synthetic_bench_db_path);
    let summary = ensure_synthetic_benchmark_fixture(&output, args.force)
        .expect("failed to generate synthetic benchmark fixture");

    println!("Synthetic benchmark database ready: {}", output.display());
    println!("Items: {}", summary.total_items);
    println!(
        "Indexed text volume: {:.2} MB",
        summary.total_text_bytes as f64 / 1024.0 / 1024.0
    );
}
