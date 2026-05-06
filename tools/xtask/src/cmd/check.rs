//! `clipkitty check` — read-only repository invariants.
//!
//! Verifies that the pinned lockfiles (`Cargo.lock`, `flake.lock`) are tracked
//! and unchanged, that no stray SwiftPM `Package.resolved` files exist, and
//! that every `uses:` reference in `.github/workflows/` is pinned to a full
//! 40-char lowercase hex SHA.

use std::fs;

use anyhow::{anyhow, Context, Result};
use camino::Utf8PathBuf;

use crate::model::SideEffectLevel;
use crate::output::Reporter;
use crate::process::Runner;
use crate::repo::RepoRoot;

const PINNED_LOCKFILES: &[&str] = &["Cargo.lock", "flake.lock"];
const STRAY_SWIFT_RESOLVED: &[&str] = &[
    "Package.resolved",
    "Tuist/Package.resolved",
    "distribution/SparkleUpdater/Package.resolved",
];

pub fn run(dry_run: bool, reporter: &Reporter) -> Result<()> {
    let _ = SideEffectLevel::ReadOnly;
    let repo = RepoRoot::discover(reporter)?;
    if dry_run {
        reporter.info("[dry-run] would verify pinned inputs and pinned GitHub Actions");
        return Ok(());
    }
    check_pinned_actions(&repo, reporter)?;
    check_pins(&repo, reporter)
}

fn check_pins(repo: &RepoRoot, reporter: &Reporter) -> Result<()> {
    let mut errors: Vec<String> = Vec::new();

    for rel in PINNED_LOCKFILES {
        if !git_path_tracked(reporter, repo, rel)? {
            errors.push(format!("NOT TRACKED: {rel} (must be committed)"));
            continue;
        }
        if git_path_dirty(reporter, repo, rel, /* staged */ false)? {
            errors.push(format!("MODIFIED: {rel}"));
        }
        if git_path_dirty(reporter, repo, rel, /* staged */ true)? {
            errors.push(format!("STAGED CHANGES: {rel}"));
        }
    }

    for rel in STRAY_SWIFT_RESOLVED {
        if repo.join(rel).as_std_path().exists() {
            errors.push(format!(
                "STRAY SWIFTPM STATE: {rel} (Swift pins belong in nix/lib.nix)"
            ));
        }
    }

    if errors.is_empty() {
        reporter.success(
            "Pinned inputs are committed, unchanged, and free of stray SwiftPM lockfiles.",
        );
        Ok(())
    } else {
        for err in &errors {
            reporter.info(err);
        }
        reporter.info("");
        Err(anyhow!("Pinned-input drift detected."))
    }
}

fn git_path_tracked(reporter: &Reporter, repo: &RepoRoot, rel: &str) -> Result<bool> {
    let output = Runner::new(reporter, "git")
        .args(["ls-files", "--error-unmatch"])
        .arg(rel)
        .cwd(repo.as_path())
        .capture_stdout()
        .capture_stderr()
        .output_status()
        .with_context(|| format!("running git ls-files for {rel}"))?;
    Ok(output.status.success())
}

fn git_path_dirty(reporter: &Reporter, repo: &RepoRoot, rel: &str, staged: bool) -> Result<bool> {
    let mut cmd = Runner::new(reporter, "git").args(["diff", "--exit-code"]);
    if staged {
        cmd = cmd.arg("--cached");
    }
    let output = cmd
        .arg("--")
        .arg(rel)
        .cwd(repo.as_path())
        .capture_stdout()
        .capture_stderr()
        .output_status()
        .with_context(|| {
            format!(
                "running `git diff{} --exit-code -- {rel}`",
                if staged { " --cached" } else { "" }
            )
        })?;
    Ok(!output.status.success())
}

fn check_pinned_actions(repo: &RepoRoot, reporter: &Reporter) -> Result<()> {
    let workflows = repo.join(".github/workflows");
    if !workflows.as_std_path().is_dir() {
        reporter.info(&format!("No workflows directory found at {workflows}"));
        return Ok(());
    }

    let mut errors = 0usize;
    let mut walker = vec![workflows.clone()];
    while let Some(dir) = walker.pop() {
        for entry in fs::read_dir(dir.as_std_path()).with_context(|| format!("reading {dir}"))? {
            let entry = entry?;
            let file_type = entry.file_type()?;
            let path = Utf8PathBuf::from_path_buf(entry.path())
                .map_err(|p| anyhow!("non-UTF-8 path: {p:?}"))?;
            if file_type.is_dir() {
                walker.push(path);
                continue;
            }
            if !matches!(path.extension(), Some("yml") | Some("yaml")) {
                continue;
            }
            let contents = fs::read_to_string(path.as_std_path())
                .with_context(|| format!("reading {path}"))?;
            for (lineno, raw_line) in contents.lines().enumerate() {
                let trimmed = raw_line.trim_start();
                if trimmed.starts_with('#') {
                    continue;
                }
                let Some(uses_ref) = extract_uses(trimmed) else {
                    continue;
                };
                if uses_ref.starts_with("docker://") || uses_ref.starts_with("./") {
                    continue;
                }
                if !is_full_sha_pin(&uses_ref) {
                    let rel = path.strip_prefix(repo.as_path()).unwrap_or(path.as_path());
                    reporter.info(&format!("UNPINNED: {rel}:{}: {uses_ref}", lineno + 1));
                    errors += 1;
                }
            }
        }
    }

    if errors > 0 {
        reporter.info("");
        return Err(anyhow!(
            "Found {errors} unpinned GitHub Action reference(s). Pin all actions to full commit SHAs (40 hex characters)."
        ));
    }

    reporter.success("All GitHub Actions are pinned to full SHAs.");
    Ok(())
}

fn extract_uses(line: &str) -> Option<String> {
    let tail = line.strip_prefix("uses:")?;
    let before_comment = tail.split('#').next().unwrap_or(tail);
    let cleaned = before_comment
        .trim()
        .trim_matches(|c| c == '"' || c == '\'');
    if cleaned.is_empty() {
        None
    } else {
        Some(cleaned.to_string())
    }
}

fn is_full_sha_pin(reference: &str) -> bool {
    let Some((_, sha)) = reference.rsplit_once('@') else {
        return false;
    };
    sha.len() == 40
        && sha
            .chars()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_full_sha_pin_accepts_40_char_lowercase_hex() {
        assert!(is_full_sha_pin(
            "actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683"
        ));
    }

    #[test]
    fn is_full_sha_pin_rejects_tags_and_short_shas() {
        assert!(!is_full_sha_pin("actions/checkout@v4"));
        assert!(!is_full_sha_pin("actions/checkout@11bd719"));
        assert!(!is_full_sha_pin("actions/checkout"));
        assert!(!is_full_sha_pin(
            "actions/checkout@11BD71901BBE5B1630CEEA73D27597364C9AF683"
        ));
    }

    #[test]
    fn extract_uses_strips_inline_comments_and_quotes() {
        assert_eq!(
            extract_uses("uses: actions/checkout@abc  # pin"),
            Some("actions/checkout@abc".to_string())
        );
        assert_eq!(
            extract_uses("uses: \"actions/checkout@abc\""),
            Some("actions/checkout@abc".to_string())
        );
        assert_eq!(extract_uses("steps:"), None);
    }
}
