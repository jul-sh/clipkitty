//! Release version resolution.
//!
//! The marketing version is `MAJOR.MINOR.<commit-count>`, where `MAJOR.MINOR`
//! comes from `MARKETING_VERSION` in `Project.swift` and the patch is the
//! total commit count on `HEAD`. The build number is just the commit count.
//!
//! This is the single source of truth for both the GitHub release tag and
//! the `CFBundleShortVersionString` / `CFBundleVersion` stamped into every
//! shipped app bundle. Keeping them wired together avoids the class of bug
//! where the release tag and the installed app disagree — which in turn
//! would make Sparkle compare stale numbers and silently skip updates.

use std::fs;

use anyhow::{anyhow, Context, Result};

use crate::output::Reporter;
use crate::process::Runner;
use crate::repo::RepoRoot;

/// Marketing version + build number for one release build.
#[derive(Debug, Clone)]
pub struct ResolvedVersion {
    /// `CFBundleShortVersionString` — e.g. `1.12.1225`.
    pub version: String,
    /// `CFBundleVersion` — the bare commit count, e.g. `1225`.
    pub build_number: String,
}

/// Resolve the release version for the current repo state.
pub fn resolve(repo: &RepoRoot, reporter: &Reporter) -> Result<ResolvedVersion> {
    let (major, minor) = read_base_major_minor(repo)?;
    let commit_count = commit_count(repo, reporter)?;
    Ok(ResolvedVersion {
        version: format!("{major}.{minor}.{commit_count}"),
        build_number: commit_count,
    })
}

fn read_base_major_minor(repo: &RepoRoot) -> Result<(String, String)> {
    let path = repo.join("Project.swift");
    let text = fs::read_to_string(path.as_std_path())
        .with_context(|| format!("reading {path}"))?;
    let base = text
        .lines()
        .find_map(parse_marketing_version_line)
        .ok_or_else(|| anyhow!("no `MARKETING_VERSION` entry in {path}"))?;

    let mut parts = base.split('.');
    let major = parts
        .next()
        .ok_or_else(|| anyhow!("MARKETING_VERSION `{base}` missing major component"))?
        .to_string();
    let minor = parts
        .next()
        .ok_or_else(|| anyhow!("MARKETING_VERSION `{base}` missing minor component"))?
        .to_string();
    Ok((major, minor))
}

fn parse_marketing_version_line(line: &str) -> Option<String> {
    let trimmed = line.trim_start();
    let rest = trimmed.strip_prefix("\"MARKETING_VERSION\"")?;
    let rest = rest.trim_start().strip_prefix(':')?.trim_start();
    let rest = rest.strip_prefix('"')?;
    let end = rest.find('"')?;
    Some(rest[..end].to_string())
}

fn commit_count(repo: &RepoRoot, reporter: &Reporter) -> Result<String> {
    let output = Runner::new(reporter, "git")
        .args(["rev-list", "--count", "HEAD"])
        .cwd(repo.as_path())
        .output()
        .context("counting commits on HEAD")?;
    let count = output.stdout_string()?.trim().to_string();
    if count.is_empty() || !count.chars().all(|c| c.is_ascii_digit()) {
        return Err(anyhow!("`git rev-list --count HEAD` returned `{count}`"));
    }
    Ok(count)
}

#[cfg(test)]
mod tests {
    use super::parse_marketing_version_line;

    #[test]
    fn parses_canonical_line() {
        assert_eq!(
            parse_marketing_version_line("            \"MARKETING_VERSION\": \"1.12.0\","),
            Some("1.12.0".to_string())
        );
    }

    #[test]
    fn ignores_unrelated_lines() {
        assert_eq!(parse_marketing_version_line("\"OTHER\": \"1.2.3\","), None);
        assert_eq!(parse_marketing_version_line("// MARKETING_VERSION = 1.0"), None);
    }

    #[test]
    fn tolerates_whitespace_variants() {
        assert_eq!(
            parse_marketing_version_line("\"MARKETING_VERSION\":\"9.9.9\""),
            Some("9.9.9".to_string())
        );
    }
}
