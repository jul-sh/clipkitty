use std::process::ExitCode;

use clap::Parser;

use xtask::cli::Cli;
use xtask::cmd;
use xtask::output::Reporter;

fn main() -> ExitCode {
    let cli = Cli::parse();
    let reporter = Reporter::new(cli.verbose);
    match cmd::dispatch(&cli, &reporter) {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            reporter.error(&format!("{err:#}"));
            ExitCode::from(1)
        }
    }
}
