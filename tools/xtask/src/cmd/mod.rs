//! Subcommand dispatcher.

use anyhow::Result;

use crate::cli::{Cli, TopLevel};
use crate::output::Reporter;

pub mod app;
pub mod build;
pub mod marketing;
pub mod perf;
pub mod precommit;
pub mod release;
pub(crate) mod secrets;
pub mod sign;

pub fn dispatch(cli: &Cli, reporter: &Reporter) -> Result<()> {
    match &cli.command {
        TopLevel::App(args) => app::run(args, cli.dry_run, reporter),
        TopLevel::Release(cmd) => release::run(cmd, cli.dry_run, reporter),
        TopLevel::Marketing(cmd) => marketing::run(cmd, cli.dry_run, reporter),
        TopLevel::Perf(args) => perf::run(args, cli.dry_run, reporter),
        TopLevel::Internal(cmd) => precommit::run(cmd, cli.dry_run, reporter),
    }
}
