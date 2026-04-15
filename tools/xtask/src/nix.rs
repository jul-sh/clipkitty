//! Nix host-tool wrappers used by `clipkitty build` / `clipkitty sign`.
//!
//! These functions own `nix build` invocations so every call-site uses the
//! same flake-attribute conventions and out-link naming rules. Callers pass
//! typed arguments; this module hands them to `nix` through `process::Runner`.

use anyhow::Result;
use camino::{Utf8Path, Utf8PathBuf};

use crate::output::Reporter;
use crate::process::Runner;

/// Run `nix build .#<attr>` with a stable out-link path, returning the
/// `result-<suffix>` symlink location.
pub fn build_out_link(
    reporter: &Reporter,
    repo_root: &Utf8Path,
    attr: &str,
    link_suffix: &str,
) -> Result<Utf8PathBuf> {
    let out_link = repo_root.join(format!("result-{link_suffix}"));
    Runner::new(reporter, "nix")
        .arg("build")
        .arg(format!(".#{attr}"))
        .arg("--out-link")
        .arg(out_link.as_std_path())
        .cwd(repo_root)
        .run()?;
    Ok(out_link)
}
