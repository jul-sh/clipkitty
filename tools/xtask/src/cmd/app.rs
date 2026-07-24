//! `clipkitty app` — stage the public app artifacts users actually care about.

use anyhow::Result;

use crate::cli::{AppArgs, AppTarget};
use crate::cmd::{build, sign};
use crate::model::MacVariant;
use crate::output::Reporter;
use crate::repo::RepoRoot;
use crate::version;

pub fn run(args: &AppArgs, dry_run: bool, reporter: &Reporter) -> Result<()> {
    let repo = RepoRoot::discover(reporter)?;
    let resolved = version::resolve(&repo, reporter)?;
    match args.target {
        AppTarget::Hardened => sign::sign_app(
            &repo,
            &sign::SignAppRequest {
                target: sign::SignableMacVariant::Hardened,
                build_version: resolved,
            },
            dry_run,
            reporter,
        ),
        AppTarget::AppStore => build::stage_app(
            &repo,
            &build::BuildAppRequest {
                variant: MacVariant::AppStore,
                build_version: Some(resolved),
            },
            dry_run,
            reporter,
        ),
    }
}
