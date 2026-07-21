//! Shared AppIcon rendering.
//!
//! `AppIcon.icon` is the source of truth. Public-site assets and the legacy
//! macOS asset catalog PNG are rendered from it so README and App Store
//! distribution cannot drift when the Icon Composer document changes.

use std::{fs, path::Path};

use anyhow::{anyhow, Context, Result};

use crate::output::Reporter;
use crate::process::Runner;
use crate::repo::RepoRoot;

/// Candidate ictool locations, preferring stable Xcode over the beta.
const ICTOOL_PATHS: [&str; 2] = [
    "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool",
    "/Applications/Xcode-beta.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool",
];

fn ictool_path() -> Result<&'static str> {
    ICTOOL_PATHS
        .iter()
        .copied()
        .find(|path| Path::new(path).is_file())
        .ok_or_else(|| {
            anyhow!(
                "ictool not found at any of: {}; install Xcode with Icon Composer",
                ICTOOL_PATHS.join(", ")
            )
        })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AppIconRenderTarget {
    PublicSite,
    MacAssetCatalog,
}

pub(crate) fn render_app_icon(
    repo: &RepoRoot,
    target: AppIconRenderTarget,
    dry_run: bool,
    reporter: &Reporter,
) -> Result<()> {
    let icon_bundle = repo.join("AppIcon.icon");
    let (output, width, height, scale, label) = match target {
        AppIconRenderTarget::PublicSite => {
            (repo.join("build/site/icon.png"), "512", "512", "1", "icon")
        }
        AppIconRenderTarget::MacAssetCatalog => (
            repo.join("Sources/MacApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png"),
            "512",
            "512",
            "2",
            "macOS app icon asset",
        ),
    };

    if dry_run {
        reporter.info(&format!("[dry-run] would export {icon_bundle} -> {output}"));
        return Ok(());
    }

    let ictool = ictool_path()?;
    if !icon_bundle.as_std_path().is_dir() {
        return Err(anyhow!("icon bundle not found: {icon_bundle}"));
    }
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent.as_std_path())
            .with_context(|| format!("creating icon output directory: {parent}"))?;
    }

    Runner::new(reporter, ictool)
        .arg(icon_bundle.as_std_path())
        .args(["--export-image", "--output-file"])
        .arg(output.as_std_path())
        .args([
            "--platform",
            "macOS",
            "--rendition",
            "Default",
            "--width",
            width,
            "--height",
            height,
            "--scale",
            scale,
        ])
        .cwd(repo.as_path())
        .run()?;
    reporter.success(&format!("Exported {label} -> {output}"));
    Ok(())
}
