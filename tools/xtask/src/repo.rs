//! Repository-root discovery.
//!
//! Every subcommand must resolve paths against the same root. We look up the
//! enclosing git checkout so behaviour is identical regardless of whether the
//! CLI is invoked directly, via `cargo run`, or from a legacy shell shim.

use std::env;

use anyhow::{anyhow, Context, Result};
use camino::{Utf8Path, Utf8PathBuf};

use crate::output::Reporter;
use crate::process::Runner;

/// A repository root: guaranteed to exist, resolved once per CLI invocation.
#[derive(Debug, Clone)]
pub struct RepoRoot(Utf8PathBuf);

impl RepoRoot {
    pub fn discover(reporter: &Reporter) -> Result<Self> {
        if let Ok(override_root) = env::var("CLIPKITTY_REPO_ROOT") {
            let path = Utf8PathBuf::from(override_root);
            if path.is_dir() {
                return Ok(Self(path));
            }
            return Err(anyhow!("CLIPKITTY_REPO_ROOT=`{path}` is not a directory"));
        }

        let cwd = env::current_dir().context("reading current working directory")?;
        let cwd = Utf8PathBuf::from_path_buf(cwd).map_err(|p| anyhow!("non-UTF-8 cwd: {p:?}"))?;

        let out = Runner::new(reporter, "git")
            .args(["rev-parse", "--show-toplevel"])
            .cwd(&cwd)
            .output()
            .context("finding git repository root")?;
        let root = out.stdout_string()?.trim().to_string();
        if root.is_empty() {
            return Err(anyhow!("git rev-parse returned empty toplevel"));
        }
        let root = Utf8PathBuf::from(root);
        if !root.is_dir() {
            return Err(anyhow!("resolved repo root `{root}` is not a directory"));
        }
        Ok(Self(root))
    }

    pub fn as_path(&self) -> &Utf8Path {
        &self.0
    }

    pub fn join(&self, rel: impl AsRef<Utf8Path>) -> Utf8PathBuf {
        self.0.join(rel)
    }
}
