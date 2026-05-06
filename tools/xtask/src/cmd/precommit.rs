//! `clipkitty __internal pre-commit` — runs SwiftFormat, SwiftLint, and the
//! localization-coverage scan against staged Swift files.
//!
//! Invoked by the git hook installed via `make install-hooks`. The hook script
//! lives in the Makefile so the install path is shell, not Rust.

use std::collections::BTreeSet;
use std::fs;

use anyhow::{anyhow, Context, Result};
use camino::{Utf8Path, Utf8PathBuf};
use serde::Deserialize;

use crate::cli::InternalCmd;
use crate::model::SideEffectLevel;
use crate::output::Reporter;
use crate::process::Runner;
use crate::repo::RepoRoot;

pub fn run(cmd: &InternalCmd, dry_run: bool, reporter: &Reporter) -> Result<()> {
    match cmd {
        InternalCmd::PreCommit(_) => {
            let _ = SideEffectLevel::LocalMutation;
            let repo = RepoRoot::discover(reporter)?;
            run_pre_commit(&repo, dry_run, reporter)
        }
    }
}

fn run_pre_commit(repo: &RepoRoot, dry_run: bool, reporter: &Reporter) -> Result<()> {
    if dry_run {
        reporter.info("[dry-run] would run the pre-commit formatting/lint/localization checks");
        return Ok(());
    }

    let staged_swift_files = staged_swift_files(repo, reporter)?;
    if staged_swift_files.is_empty() {
        return Ok(());
    }

    reporter.info("Running SwiftFormat on staged files...");
    for file in &staged_swift_files {
        let path = repo.join(file);
        if !path.as_std_path().is_file() {
            continue;
        }
        Runner::new(reporter, "swiftformat")
            .arg(path.as_std_path())
            .args(["--swiftversion", "5"])
            .cwd(repo.as_path())
            .run()?;
        Runner::new(reporter, "git")
            .arg("add")
            .arg(path.as_std_path())
            .cwd(repo.as_path())
            .run()?;
    }

    reporter.info("Running SwiftLint on staged files...");
    let mut hardcoded_found = false;
    for file in &staged_swift_files {
        let path = repo.join(file);
        if !path.as_std_path().is_file() {
            continue;
        }
        let output = Runner::new(reporter, "swiftlint")
            .args(["lint", "--path"])
            .arg(path.as_std_path())
            .args(["--config", ".swiftlint.yml"])
            .cwd(repo.as_path())
            .capture_stdout()
            .capture_stderr()
            .output_status()?;
        let combined = format!(
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        if combined.contains("Hardcoded") {
            print!("{combined}");
            hardcoded_found = true;
        }
    }
    if hardcoded_found {
        return Err(anyhow!(
            "hardcoded UI strings detected; use String(localized:) for user-facing text"
        ));
    }

    reporter.info("Checking localization coverage for staged Swift files...");
    check_localization_files(repo, &staged_swift_files, reporter)
}

fn staged_swift_files(repo: &RepoRoot, reporter: &Reporter) -> Result<Vec<String>> {
    let output = Runner::new(reporter, "git")
        .args(["diff", "--cached", "--name-only", "--diff-filter=ACM"])
        .cwd(repo.as_path())
        .output()?;
    Ok(output
        .stdout_string()?
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && line.ends_with(".swift"))
        .map(ToOwned::to_owned)
        .collect())
}

#[derive(Deserialize)]
struct XcStringsFile {
    strings: serde_json::Map<String, serde_json::Value>,
}

fn check_localization_files(
    repo: &RepoRoot,
    files: &[String],
    reporter: &Reporter,
) -> Result<()> {
    let mac_catalog = repo.join("Sources/MacApp/Resources/Localizable.xcstrings");
    let ios_catalog = repo.join("Sources/iOSApp/Resources/Localizable.xcstrings");

    if !mac_catalog.as_std_path().is_file() && !ios_catalog.as_std_path().is_file() {
        return Err(anyhow!("No localization catalog found"));
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

    let files: Vec<Utf8PathBuf> = files.iter().map(Utf8PathBuf::from).collect();

    let mut missing: Vec<String> = Vec::new();
    for file in &files {
        let abs = if file.is_absolute() {
            file.clone()
        } else {
            repo.join(file)
        };
        if !abs.as_std_path().is_file() {
            continue;
        }
        let contents = fs::read_to_string(abs.as_std_path())
            .with_context(|| format!("reading {abs}"))?;
        let keys = extract_localized_keys(&contents);
        for key in keys {
            if key.contains('\\') {
                continue;
            }
            if !catalog_keys.contains(&key) {
                let display = abs.strip_prefix(repo.as_path()).unwrap_or(abs.as_path());
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
    use super::extract_localized_keys;

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
        assert!(keys.iter().any(|k| k.contains('\\')));
    }
}
