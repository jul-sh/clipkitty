//! Subcommand dispatcher.

use anyhow::Result;

use crate::cli::{Cli, TopLevel};
use crate::output::Reporter;

pub mod app;
pub mod build;
pub mod check;
pub mod env;
pub mod marketing;
pub mod perf;
pub mod release;
pub mod secrets;
pub mod sign;
pub mod site;

pub fn dispatch(cli: &Cli, reporter: &Reporter) -> Result<()> {
    match &cli.command {
        TopLevel::Check => check::run(cli.dry_run, reporter),
        TopLevel::Env(cmd) => env::run(cmd, cli.dry_run, reporter),
        TopLevel::Workspace => build::run_generate(cli.dry_run, reporter),
        TopLevel::App(args) => app::run(args, cli.dry_run, reporter),
        TopLevel::Release(cmd) => release::run(cmd, cli.dry_run, reporter),
        TopLevel::Marketing(cmd) => marketing::run(cmd, cli.dry_run, reporter),
        TopLevel::Perf(args) => perf::run(args, cli.dry_run, reporter),
        TopLevel::Secrets(cmd) => secrets::run(cmd, cli.dry_run, reporter),
        TopLevel::Site(cmd) => site::run(cmd, cli.dry_run, reporter),
        TopLevel::Internal(cmd) => env::run_internal(cmd, cli.dry_run, reporter),
    }
}
