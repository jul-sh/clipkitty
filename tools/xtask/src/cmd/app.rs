//! `clipkitty app` — stage the public app artifacts users actually care about.

use anyhow::Result;

use crate::cli::{AppArgs, AppTarget};
use crate::cmd::{build, sign};
use crate::model::{MacVariant, SideEffectLevel};
use crate::output::Reporter;
use crate::repo::RepoRoot;
use crate::version;

pub fn run(args: &AppArgs, dry_run: bool, reporter: &Reporter) -> Result<()> {
    let _ = SideEffectLevel::LocalMutation;
    let repo = RepoRoot::discover(reporter)?;
    let resolved = version::resolve(&repo, reporter)?;
    match args.target {
        AppTarget::Hardened => sign::sign_app(
            &repo,
            &sign::SignAppRequest {
                variant: MacVariant::Hardened,
                version: Some(resolved.version),
                build_number: Some(resolved.build_number),
            },
            dry_run,
            reporter,
        ),
        AppTarget::AppStore => build::stage_app(
            &repo,
            &build::BuildAppRequest {
                variant: MacVariant::AppStore,
                version: Some(resolved.version),
                build_number: Some(resolved.build_number),
            },
            dry_run,
            reporter,
        ),
    }
}
