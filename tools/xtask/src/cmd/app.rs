//! `clipkitty app` — stage the public app artifacts users actually care about.

use anyhow::Result;

use crate::cli::{AppArgs, AppTarget};
use crate::cmd::{build, sign};
use crate::model::{MacVariant, SideEffectLevel};
use crate::output::Reporter;
use crate::repo::RepoRoot;

pub fn run(args: &AppArgs, dry_run: bool, reporter: &Reporter) -> Result<()> {
    let _ = SideEffectLevel::LocalMutation;
    let repo = RepoRoot::discover(reporter)?;
    match args.target {
        AppTarget::Hardened => sign::sign_app(
            &repo,
            &sign::SignAppRequest {
                variant: MacVariant::Hardened,
                version: None,
                build_number: None,
            },
            dry_run,
            reporter,
        ),
        AppTarget::AppStore => build::stage_app(
            &repo,
            &build::BuildAppRequest {
                variant: MacVariant::AppStore,
                version: None,
                build_number: None,
            },
            dry_run,
            reporter,
        ),
    }
}
