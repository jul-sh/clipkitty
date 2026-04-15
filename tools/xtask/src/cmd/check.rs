//! Read-only repository checks.
//!
//! Every command in this module is `SideEffectLevel::ReadOnly`: they never
//! mutate the worktree, never touch credentials, and can always run on CI.

use std::collections::BTreeSet;
use std::fs;

use anyhow::{anyhow, Context, Result};
use camino::{Utf8Path, Utf8PathBuf};
use serde::Deserialize;

use crate::model::SideEffectLevel;
use crate::output::Reporter;
use crate::process::Runner;
use crate::repo::RepoRoot;

pub fn run(dry_run: bool, reporter: &Reporter) -> Result<()> {
    let _ = SideEffectLevel::ReadOnly;
    let repo = RepoRoot::discover(reporter)?;
    if dry_run {
        reporter.info("[dry-run] would verify pinned inputs and pinned GitHub Actions");
        return Ok(());
    }
    check_pinned_actions(&repo, false, reporter)?;
    check_pins(&repo, false, reporter)
}

const PINNED_LOCKFILES: &[&str] = &["Cargo.lock", "flake.lock"];
const STRAY_SWIFT_RESOLVED: &[&str] = &[
    "Package.resolved",
    "Tuist/Package.resolved",
    "distribution/SparkleUpdater/Package.resolved",
];

fn check_pins(repo: &RepoRoot, dry_run: bool, reporter: &Reporter) -> Result<()> {
    if dry_run {
        reporter.info(&format!(
            "[dry-run] would verify {} lockfile(s) and absence of {} SwiftPM stray files",
            PINNED_LOCKFILES.len(),
            STRAY_SWIFT_RESOLVED.len()
        ));
        return Ok(());
    }

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
        let abs = repo.join(rel);
        if abs.as_std_path().exists() {
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

fn check_pinned_actions(repo: &RepoRoot, dry_run: bool, reporter: &Reporter) -> Result<()> {
    let workflows = repo.join(".github/workflows");
    if !workflows.as_std_path().is_dir() {
        reporter.info(&format!("No workflows directory found at {workflows}"));
        return Ok(());
    }

    if dry_run {
        reporter.info(&format!(
            "[dry-run] would scan `{workflows}` for unpinned GitHub Action references"
        ));
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
            let is_workflow = matches!(path.extension(), Some("yml") | Some("yaml"));
            if !is_workflow {
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

#[derive(Deserialize)]
struct XcStringsFile {
    strings: serde_json::Map<String, serde_json::Value>,
}

pub(crate) fn check_localization_files(
    repo: &RepoRoot,
    files: &[String],
    dry_run: bool,
    reporter: &Reporter,
) -> Result<()> {
    let mac_catalog = repo.join("Sources/MacApp/Resources/Localizable.xcstrings");
    let ios_catalog = repo.join("Sources/iOSApp/Resources/Localizable.xcstrings");

    if !mac_catalog.as_std_path().is_file() && !ios_catalog.as_std_path().is_file() {
        return Err(anyhow!("No localization catalog found"));
    }

    if dry_run {
        reporter.info("[dry-run] would scan Swift sources for unlocalized strings");
        return Ok(());
    }

    let mut catalog_keys: BTreeSet<String> = BTreeSet::new();
    for catalog in [&mac_catalog, &ios_catalog] {
        if !catalog.as_std_path().is_file() {
            continue;
        }
        let text = fs::read_to_string(catalog.as_std_path())
            .with_context(|| format!("reading {catalog}"))?;
        let parsed: XcStringsFile =
            serde_json::from_str(&text).with_context(|| format!("parsing {catalog}"))?;
        for key in parsed.strings.keys() {
            catalog_keys.insert(key.clone());
        }
    }

    let files: Vec<Utf8PathBuf> = if files.is_empty() {
        collect_swift_files(&repo.join("Sources"))?
    } else {
        files.iter().map(Utf8PathBuf::from).collect()
    };

    let mut missing: Vec<String> = Vec::new();
    for file in &files {
        if !file.as_std_path().is_file() {
            continue;
        }
        let contents =
            fs::read_to_string(file.as_std_path()).with_context(|| format!("reading {file}"))?;
        let keys = extract_localized_keys(&contents);
        for key in keys {
            if key.contains('\\') {
                continue;
            }
            if !catalog_keys.contains(&key) {
                let display = file.strip_prefix(repo.as_path()).unwrap_or(file.as_path());
                missing.push(format!("{display}: \"{key}\""));
            }
        }
    }

    if !missing.is_empty() {
        report_missing_localizations(reporter, &mac_catalog, &ios_catalog, &missing);
        return Err(anyhow!(
            "Missing localization catalog entries ({} key(s))",
            missing.len()
        ));
    }

    reporter.success("✓ All localized strings have catalog entries");
    Ok(())
}

fn collect_swift_files(dir: &Utf8Path) -> Result<Vec<Utf8PathBuf>> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = fs::read_dir(d.as_std_path()) else {
            continue;
        };
        for entry in entries {
            let entry = entry?;
            let path = Utf8PathBuf::from_path_buf(entry.path())
                .map_err(|p| anyhow!("non-UTF-8 path: {p:?}"))?;
            let ft = entry.file_type()?;
            if ft.is_dir() {
                stack.push(path);
            } else if path.extension() == Some("swift") {
                out.push(path);
            }
        }
    }
    Ok(out)
}

fn extract_localized_keys(source: &str) -> Vec<String> {
    let mut keys = Vec::new();
    extract_after_marker(source, "String(localized: \"", '"', &mut keys);
    extract_after_marker(source, "NSLocalizedString(\"", '"', &mut keys);
    keys
}

fn extract_after_marker(source: &str, marker: &str, terminator: char, out: &mut Vec<String>) {
    let mut cursor = 0;
    while let Some(start) = source[cursor..].find(marker) {
        let key_start = cursor + start + marker.len();
        let Some(end_offset) = source[key_start..].find(terminator) else {
            return;
        };
        let key = &source[key_start..key_start + end_offset];
        out.push(key.to_string());
        cursor = key_start + end_offset + 1;
    }
}

fn report_missing_localizations(
    reporter: &Reporter,
    mac_catalog: &Utf8Path,
    ios_catalog: &Utf8Path,
    missing: &[String],
) {
    reporter.info("");
    reporter.info("Missing localization catalog entries!");
    reporter.info("");
    reporter
        .info("The following strings are used in code but missing from any localization catalog:");
    reporter.info(&format!("  {mac_catalog}"));
    reporter.info(&format!("  {ios_catalog}"));
    reporter.info("");
    for entry in missing {
        reporter.info(&format!("  - {entry}"));
    }
    reporter.info("");
    reporter.info("To fix: add each missing key to the appropriate catalog with translations for all supported languages.");
    reporter.info(&format!("  Mac strings: {mac_catalog}"));
    reporter.info(&format!("  iOS strings: {ios_catalog}"));
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
        // Uppercase hex would break `grep -E '[0-9a-f]{40}'` semantics.
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

    #[test]
    fn extract_localized_keys_covers_both_apis() {
        let source = r#"
            let a = String(localized: "Hello")
            let b = NSLocalizedString("World", comment: "")
            let c = String(localized: "Interpolated \(value)")
            let d = String(localized: "Another")
        "#;
        let keys = extract_localized_keys(source);
        assert!(keys.contains(&"Hello".to_string()));
        assert!(keys.contains(&"World".to_string()));
        assert!(keys.contains(&"Another".to_string()));
        // Interpolated keys are kept here but filtered at the call site.
        assert!(keys.iter().any(|k| k.contains('\\')));
    }
}
