//! `clipkitty build` — nix-driven materialisation and app builds.
//!
//! Both subcommands invoke the shared `nix` runner. Versioning and bundle
//! staging happen after the `nix build` call, so the store derivation stays
//! deterministic while per-commit metadata lands on a mutable copy.

use std::fs;
use std::os::unix::fs::PermissionsExt;

use anyhow::{anyhow, Context, Result};
use camino::{Utf8Path, Utf8PathBuf};

use crate::apple;
use crate::model::{MacVariant, SideEffectLevel};
use crate::nix;
use crate::output::Reporter;
use crate::process::Runner;
use crate::repo::RepoRoot;

pub fn run_generate(dry_run: bool, reporter: &Reporter) -> Result<()> {
    let _ = SideEffectLevel::LocalMutation;
    let repo = RepoRoot::discover(reporter)?;
    generate(&repo, dry_run, reporter)
}

const APP_NAME: &str = "ClipKitty";
const OVERLAY_FILES: &[&str] = &[
    "Sources/ClipKittyRust/purrFFI.h",
    "Sources/ClipKittyRust/module.modulemap",
    "Sources/ClipKittyRust/libpurr.a",
    "Sources/ClipKittyRust/ios-device/libpurr.a",
    "Sources/ClipKittyRust/ios-simulator/libpurr.a",
    "Sources/ClipKittyRustWrapper/purr.swift",
];
const STRAY_SWIFTPM: &[&str] = &[
    "Package.resolved",
    "Tuist/Package.resolved",
    "distribution/SparkleUpdater/Package.resolved",
];

pub(crate) struct BuildAppRequest {
    pub variant: MacVariant,
    pub version: Option<String>,
    pub build_number: Option<String>,
}

pub(crate) struct ArchiveIosRequest {
    pub version: String,
    pub build_number: String,
    pub archive_path: Option<Utf8PathBuf>,
}

pub(crate) fn generate(repo: &RepoRoot, dry_run: bool, reporter: &Reporter) -> Result<()> {
    reporter.info("Materialising generated Xcode project via nix...");
    if dry_run {
        reporter.info("[dry-run] would run `nix build .#clipkitty-generated` and stage outputs");
        return Ok(());
    }

    let out_link =
        nix::build_out_link(reporter, repo.as_path(), "clipkitty-generated", "generated")?;

    remove_path(&repo.join(format!("{APP_NAME}.xcworkspace")))?;
    remove_path(&repo.join(format!("{APP_NAME}.xcodeproj")))?;
    remove_path(&repo.join("Tuist/.build"))?;
    remove_path(&repo.join("Derived"))?;
    for stray in STRAY_SWIFTPM {
        remove_path(&repo.join(stray))?;
    }

    copy_dir(
        reporter,
        &out_link.join(format!("{APP_NAME}.xcworkspace")),
        &repo.join(format!("{APP_NAME}.xcworkspace")),
    )?;
    copy_dir(
        reporter,
        &out_link.join(format!("{APP_NAME}.xcodeproj")),
        &repo.join(format!("{APP_NAME}.xcodeproj")),
    )?;

    let staged_tuist_build = out_link.join("Tuist/.build");
    if staged_tuist_build.as_std_path().is_dir() {
        fs::create_dir_all(repo.join("Tuist").as_std_path())?;
        copy_dir(reporter, &staged_tuist_build, &repo.join("Tuist/.build"))?;
    }

    let staged_derived = out_link.join("Derived");
    if staged_derived.as_std_path().is_dir() {
        copy_dir(reporter, &staged_derived, &repo.join("Derived"))?;
    }

    for rel in OVERLAY_FILES {
        let src = out_link.join(rel);
        if src.as_std_path().is_file() {
            let dst = repo.join(rel);
            if let Some(parent) = dst.parent() {
                fs::create_dir_all(parent.as_std_path())?;
            }
            copy_file(reporter, &src, &dst)?;
            make_user_writable(&dst)?;
        }
    }

    for rel in [
        &format!("{APP_NAME}.xcworkspace"),
        &format!("{APP_NAME}.xcodeproj"),
        &String::from("Tuist/.build"),
        &String::from("Derived"),
    ] {
        let p = repo.join(rel);
        if p.as_std_path().exists() {
            chmod_tree_user_writable(&p).ok();
        }
    }

    reporter.success("Generated Xcode project materialised into the worktree.");
    Ok(())
}

pub(crate) fn stage_app(
    repo: &RepoRoot,
    request: &BuildAppRequest,
    dry_run: bool,
    reporter: &Reporter,
) -> Result<()> {
    let variant = request.variant;
    let attr = variant.nix_attr();
    let configuration_dir = variant.configuration_dir();

    reporter.info(&format!(
        "Building {APP_NAME} via nix: .#{attr} ({configuration_dir})"
    ));

    let dest_dir = repo.join(format!("DerivedData/Build/Products/{configuration_dir}"));
    let dest_app = dest_dir.join(format!("{APP_NAME}.app"));

    if dry_run {
        reporter.info(&format!(
            "[dry-run] would `nix build .#{attr}` and stage it at {dest_app}"
        ));
        if request.version.is_some() || request.build_number.is_some() {
            reporter.info("[dry-run] would patch Info.plist with version/build metadata");
        }
        return Ok(());
    }

    let out_link = nix::build_out_link(reporter, repo.as_path(), attr, configuration_dir)?;

    fs::create_dir_all(dest_dir.as_std_path()).with_context(|| format!("creating {dest_dir}"))?;
    remove_path(&dest_app)?;
    copy_dir(
        reporter,
        &out_link.join(format!("{APP_NAME}.app")),
        &dest_app,
    )?;
    chmod_tree_user_writable(&dest_app)?;

    let plist = dest_app.join("Contents/Info.plist");
    if let Some(version) = &request.version {
        reporter.info(&format!("Setting CFBundleShortVersionString = {version}"));
        apple::plist_set(reporter, &plist, "CFBundleShortVersionString", version)?;
    }
    if let Some(build_number) = &request.build_number {
        reporter.info(&format!("Setting CFBundleVersion = {build_number}"));
        apple::plist_set(reporter, &plist, "CFBundleVersion", build_number)?;
    }

    reporter.success(&format!("Staged at {dest_app}"));
    Ok(())
}

pub(crate) fn staged_app_path(repo: &RepoRoot, variant: MacVariant) -> Utf8PathBuf {
    repo.join(format!(
        "DerivedData/Build/Products/{}/{APP_NAME}.app",
        variant.configuration_dir()
    ))
}

/// Archive + export the iOS app. Defers to `xcodebuild archive` then
/// `xcodebuild -exportArchive`; the iOS variant has no nix derivation yet, so
/// this step lives at the Apple-toolchain boundary.
pub(crate) fn archive_ios(
    repo: &RepoRoot,
    request: &ArchiveIosRequest,
    dry_run: bool,
    reporter: &Reporter,
) -> Result<()> {
    let archive_path = request
        .archive_path
        .clone()
        .unwrap_or_else(|| repo.join("DerivedData/ClipKittyiOS.xcarchive"));
    let export_dir = repo.as_path().to_path_buf();
    let export_plist = repo.join("distribution/ExportOptions-iOS.plist");
    let workspace = repo.join(format!("{APP_NAME}.xcworkspace"));

    if dry_run {
        reporter.info(&format!(
            "[dry-run] would archive iOS {} ({}) → {archive_path}, export → {export_dir}",
            request.version, request.build_number
        ));
        return Ok(());
    }

    if !workspace.as_std_path().is_dir() {
        return Err(anyhow!(
            "workspace {workspace} not found — run `clipkitty workspace` first"
        ));
    }
    if !export_plist.as_std_path().is_file() {
        return Err(anyhow!("export options plist not found at {export_plist}"));
    }

    let archive_parent = archive_path
        .parent()
        .ok_or_else(|| anyhow!("archive path has no parent: {archive_path}"))?;
    fs::create_dir_all(archive_parent.as_std_path())?;
    remove_path(&archive_path)?;

    reporter.info(&format!(
        "Archiving iOS {} ({}) → {archive_path}",
        request.version, request.build_number
    ));
    Runner::new(reporter, "xcodebuild")
        .args(["archive", "-workspace"])
        .arg(workspace.as_std_path())
        .args([
            "-scheme",
            "ClipKittyiOS-AppStore",
            "-destination",
            "generic/platform=iOS",
            "-archivePath",
        ])
        .arg(archive_path.as_std_path())
        .arg(format!("MARKETING_VERSION={}", request.version))
        .arg(format!("CURRENT_PROJECT_VERSION={}", request.build_number))
        .cwd(repo.as_path())
        .sanitize_for_xcode()
        .run()?;

    reporter.info(&format!("Exporting iOS archive → {export_dir}"));
    Runner::new(reporter, "xcodebuild")
        .args(["-exportArchive", "-archivePath"])
        .arg(archive_path.as_std_path())
        .arg("-exportPath")
        .arg(export_dir.as_std_path())
        .arg("-exportOptionsPlist")
        .arg(export_plist.as_std_path())
        .cwd(repo.as_path())
        .sanitize_for_xcode()
        .run()?;

    reporter.success(&format!("Exported iOS archive to {export_dir}"));
    Ok(())
}

fn remove_path(path: &Utf8Path) -> Result<()> {
    let std_path = path.as_std_path();
    if std_path.is_symlink() || std_path.is_file() {
        fs::remove_file(std_path).with_context(|| format!("removing {path}"))?;
    } else if std_path.is_dir() {
        fs::remove_dir_all(std_path).with_context(|| format!("removing {path}"))?;
    }
    Ok(())
}

fn copy_dir(reporter: &Reporter, src: &Utf8Path, dst: &Utf8Path) -> Result<()> {
    if !src.as_std_path().exists() {
        return Err(anyhow!("source `{src}` does not exist"));
    }
    // `cp -R` mirrors the previous shell behaviour for symlinks and nested
    // Apple bundle layouts; re-implementing that in Rust would duplicate a
    // lot of special-case logic for what is still a host tool.
    Runner::new(reporter, "cp")
        .arg("-R")
        .arg(src.as_std_path())
        .arg(dst.as_std_path())
        .run()
}

fn copy_file(reporter: &Reporter, src: &Utf8Path, dst: &Utf8Path) -> Result<()> {
    Runner::new(reporter, "cp")
        .arg(src.as_std_path())
        .arg(dst.as_std_path())
        .run()
}

fn make_user_writable(path: &Utf8Path) -> Result<()> {
    let metadata = fs::metadata(path.as_std_path()).with_context(|| format!("stat {path}"))?;
    let mut perms = metadata.permissions();
    let mode = perms.mode() | 0o200;
    perms.set_mode(mode);
    fs::set_permissions(path.as_std_path(), perms).with_context(|| format!("chmod u+w {path}"))?;
    Ok(())
}

fn chmod_tree_user_writable(root: &Utf8Path) -> Result<()> {
    let mut stack = vec![root.to_path_buf()];
    while let Some(path) = stack.pop() {
        let metadata = match fs::symlink_metadata(path.as_std_path()) {
            Ok(m) => m,
            Err(_) => continue,
        };
        if metadata.file_type().is_symlink() {
            continue;
        }
        let mut perms = metadata.permissions();
        let mode = perms.mode() | 0o200;
        perms.set_mode(mode);
        fs::set_permissions(path.as_std_path(), perms).ok();
        if metadata.is_dir() {
            if let Ok(entries) = fs::read_dir(path.as_std_path()) {
                for entry in entries.flatten() {
                    let child = Utf8PathBuf::from_path_buf(entry.path())
                        .map_err(|p| anyhow!("non-UTF-8 child: {p:?}"))?;
                    stack.push(child);
                }
            }
        }
    }
    Ok(())
}
