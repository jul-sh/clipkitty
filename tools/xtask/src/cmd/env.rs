//! `clipkitty env` — local helpers the repo owns (git hooks, Sparkle CLI).
//!
//! Entering the pinned Nix dev shell is **not** this module's job. The
//! `Makefile` (and CI workflows) wrap every xtask invocation in
//! `nix develop --command`; xtask itself always assumes it is already running
//! inside the shell.

use std::env;
use std::fs;
use std::io::Write;

use anyhow::{anyhow, Context, Result};
use camino::Utf8PathBuf;
use tempfile::tempdir;

use crate::cli::{EnvCmd, InstallArgs, InstallTarget, InternalCmd};
use crate::cmd::check;
use crate::model::SideEffectLevel;
use crate::output::Reporter;
use crate::process::Runner;
use crate::repo::RepoRoot;

pub fn run(cmd: &EnvCmd, dry_run: bool, reporter: &Reporter) -> Result<()> {
    match cmd {
        EnvCmd::Install(args) => install(args, dry_run, reporter),
    }
}

pub fn run_internal(cmd: &InternalCmd, dry_run: bool, reporter: &Reporter) -> Result<()> {
    match cmd {
        InternalCmd::PreCommit(_) => {
            let _ = SideEffectLevel::LocalMutation;
            let repo = RepoRoot::discover(reporter)?;
            run_pre_commit_command(&repo, dry_run, reporter)
        }
    }
}

fn install(args: &InstallArgs, dry_run: bool, reporter: &Reporter) -> Result<()> {
    match args.target {
        InstallTarget::Hooks => {
            let _ = SideEffectLevel::LocalMutation;
            let repo = RepoRoot::discover(reporter)?;
            install_hooks(&repo, dry_run, reporter)
        }
        InstallTarget::SparkleCli => {
            let _ = SideEffectLevel::Networked;
            install_sparkle_cli(dry_run, reporter)
        }
    }
}

fn install_hooks(repo: &RepoRoot, dry_run: bool, reporter: &Reporter) -> Result<()> {
    let hooks_dir = git_hooks_dir(repo, reporter)?;
    let hook_path = hooks_dir.join("pre-commit");
    // The hook must work whether or not the committer is inside a dev shell.
    // If already in nix, run xtask directly; otherwise re-enter via
    // `nix develop --command`.
    let hook = r#"#!/bin/bash
set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"
if [ -n "${IN_NIX_SHELL:-}" ]; then
    exec cargo run --quiet -p xtask -- __internal pre-commit
fi
exec nix develop --no-update-lock-file --experimental-features 'nix-command flakes' "$REPO_ROOT#default" --command cargo run --quiet -p xtask -- __internal pre-commit
"#;

    if dry_run {
        reporter.info(&format!("[dry-run] would install git hook at {hook_path}"));
        return Ok(());
    }

    fs::create_dir_all(hooks_dir.as_std_path()).with_context(|| format!("creating {hooks_dir}"))?;
    fs::write(hook_path.as_std_path(), hook).with_context(|| format!("writing {hook_path}"))?;
    Runner::new(reporter, "chmod")
        .arg("+x")
        .arg(hook_path.as_std_path())
        .run()
        .with_context(|| format!("chmod +x {hook_path}"))?;
    reporter.success(&format!("Installed pre-commit hook at {hook_path}"));
    Ok(())
}

fn install_sparkle_cli(dry_run: bool, reporter: &Reporter) -> Result<()> {
    const SPARKLE_VERSION: &str = "2.9.0";
    const SPARKLE_SHA256: &str = "01e0f0ebf6614061ea816d414de50f937d64ffa6822ad572243031ca3676fe19";
    let install_dir = Utf8PathBuf::from("/tmp/sparkle");
    let archive_dir = tempdir().context("creating temporary Sparkle download dir")?;
    let archive_dir = Utf8PathBuf::from_path_buf(archive_dir.path().to_path_buf())
        .map_err(|p| anyhow!("non-UTF-8 temp path: {p:?}"))?;
    let archive_path = archive_dir.join("Sparkle.tar.xz");
    let url = format!(
        "https://github.com/sparkle-project/Sparkle/releases/download/{SPARKLE_VERSION}/Sparkle-{SPARKLE_VERSION}.tar.xz"
    );

    if dry_run {
        reporter.info(&format!(
            "[dry-run] would download Sparkle {SPARKLE_VERSION} to {install_dir}"
        ));
        return Ok(());
    }

    Runner::new(reporter, "curl")
        .arg("-sL")
        .arg(&url)
        .arg("-o")
        .arg(archive_path.as_std_path())
        .run()?;
    let checksum_input = format!("{SPARKLE_SHA256}  {archive_path}");
    Runner::new(reporter, "shasum")
        .args(["-a", "256", "--check"])
        .stdin_bytes(checksum_input)
        .run()?;
    fs::create_dir_all(install_dir.as_std_path())
        .with_context(|| format!("creating {install_dir}"))?;
    Runner::new(reporter, "tar")
        .arg("-xf")
        .arg(archive_path.as_std_path())
        .arg("-C")
        .arg(install_dir.as_std_path())
        .run()?;

    if let Ok(github_path) = env::var("GITHUB_PATH") {
        let line = format!("{}/bin\n", install_dir);
        fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&github_path)
            .with_context(|| format!("opening GITHUB_PATH file {github_path}"))?
            .write_all(line.as_bytes())
            .with_context(|| format!("writing Sparkle bin path to {github_path}"))?;
    }

    reporter.success(&format!(
        "Sparkle CLI {SPARKLE_VERSION} installed to {install_dir}"
    ));
    Ok(())
}

pub(crate) fn run_pre_commit_command(
    repo: &RepoRoot,
    dry_run: bool,
    reporter: &Reporter,
) -> Result<()> {
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
    check::check_localization_files(repo, &staged_swift_files, false, reporter)
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

fn git_hooks_dir(repo: &RepoRoot, reporter: &Reporter) -> Result<Utf8PathBuf> {
    let output = Runner::new(reporter, "git")
        .args(["rev-parse", "--git-path", "hooks"])
        .cwd(repo.as_path())
        .output()?;
    let hooks = output.stdout_string()?.trim().to_string();
    if hooks.is_empty() {
        return Err(anyhow!(
            "git rev-parse --git-path hooks returned an empty path"
        ));
    }
    Ok(repo.join(hooks))
}
