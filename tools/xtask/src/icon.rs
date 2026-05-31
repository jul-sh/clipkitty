//! Shared AppIcon rendering.
//!
//! `AppIcon.icon` is the source of truth. Public-site assets and the legacy
//! macOS asset catalog PNG are rendered from it so README and App Store
//! distribution cannot drift when the Icon Composer document changes.

use std::path::Path;

use anyhow::{anyhow, Result};

use crate::output::Reporter;
use crate::process::Runner;
use crate::repo::RepoRoot;

const ICTOOL_PATH: &str =
    "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool";

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
        AppIconRenderTarget::PublicSite => (repo.join("icon.png"), "512", "512", "1", "icon"),
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

    if !Path::new(ICTOOL_PATH).is_file() {
        return Err(anyhow!(
            "ictool not found at {ICTOOL_PATH}; install Xcode with Icon Composer"
        ));
    }
    if !icon_bundle.as_std_path().is_dir() {
        return Err(anyhow!("icon bundle not found: {icon_bundle}"));
    }

    Runner::new(reporter, ICTOOL_PATH)
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
