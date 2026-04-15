//! `clipkitty site` — public-site asset generation.
//!
//! `icon` exports the AppIcon bundle to PNG via Xcode's `ictool`. `landing-page`
//! renders README.md to HTML via `cmark-gfm`. Both are thin wrappers around
//! host tools; the CLI exists to centralise pathing, dry-run, and env checks.

use std::io::{self, Write};
use std::path::Path;

use anyhow::{anyhow, Result};
use camino::Utf8PathBuf;

use crate::cli::{SiteCmd, SiteRenderTarget};
use crate::model::SideEffectLevel;
use crate::output::Reporter;
use crate::process::Runner;
use crate::repo::RepoRoot;

pub fn run(cmd: &SiteCmd, dry_run: bool, reporter: &Reporter) -> Result<()> {
    let _ = SideEffectLevel::LocalMutation;
    let repo = RepoRoot::discover(reporter)?;
    match cmd {
        SiteCmd::Render(args) => match args.target {
            SiteRenderTarget::Icon => icon(&repo, dry_run, reporter),
            SiteRenderTarget::LandingPage => landing_page(&repo, dry_run, reporter),
        },
    }
}

const ICTOOL_PATH: &str =
    "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool";

fn icon(repo: &RepoRoot, dry_run: bool, reporter: &Reporter) -> Result<()> {
    let icon_bundle = repo.join("AppIcon.icon");
    let output = repo.join("icon.png");

    if dry_run {
        reporter.info(&format!("[dry-run] would export {icon_bundle} → {output}"));
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
            "512",
            "--height",
            "512",
            "--scale",
            "1",
        ])
        .cwd(repo.as_path())
        .run()?;
    reporter.success(&format!("Exported icon → {output}"));
    Ok(())
}

fn landing_page(repo: &RepoRoot, dry_run: bool, reporter: &Reporter) -> Result<()> {
    let readme: Utf8PathBuf = repo.join("README.md");

    if dry_run {
        reporter.info(&format!("[dry-run] would render {readme} → stdout"));
        return Ok(());
    }
    if !readme.as_std_path().is_file() {
        return Err(anyhow!("README not found: {readme}"));
    }

    let body = Runner::new(reporter, "cmark-gfm")
        .args(["--unsafe", "-e", "table"])
        .arg(readme.as_std_path())
        .cwd(repo.as_path())
        .output()?
        .stdout_string()?;
    let body = body.replace(
        "https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/",
        "",
    );

    let mut stdout = io::stdout().lock();
    stdout.write_all(LANDING_PAGE_HEAD.as_bytes())?;
    stdout.write_all(body.as_bytes())?;
    stdout.write_all(LANDING_PAGE_FOOT.as_bytes())?;
    Ok(())
}

const LANDING_PAGE_HEAD: &str = r#"<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ClipKitty — Clipboard Manager for macOS</title>
<meta name="description" content="Unlimited clipboard history with instant fuzzy search and multi-line previews. Private, fast, keyboard-driven. Free and open source for macOS.">
<style>
  :root { color-scheme: light dark; }
  * { margin: 0; padding: 0; box-sizing: border-box; }

  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    line-height: 1.7;
    max-width: 760px;
    margin: 0 auto;
    padding: 3rem 1.5rem;
    color: #1d1d1f;
    background: #fff;
  }
  @media (prefers-color-scheme: dark) {
    body { color: #f5f5f7; background: #1d1d1f; }
    a { color: #6cb4ee; }
    code { background: #2d2d2d; }
    pre { background: #2d2d2d !important; }
    table th { background: #2d2d2d; }
    table td, table th { border-color: #424245; }
  }

  h1 { font-size: 2.25rem; margin-top: 2.5rem; margin-bottom: 0.5rem; }
  h2 { font-size: 1.4rem; margin-top: 2.5rem; margin-bottom: 0.75rem; }
  h3 { font-size: 1.1rem; margin-top: 1.5rem; margin-bottom: 0.5rem; }
  p { margin-bottom: 1rem; }
  ul, ol { margin-bottom: 1rem; padding-left: 1.5rem; }
  li { margin-bottom: 0.3rem; }
  img { max-width: 100%; height: auto; border-radius: 8px; margin: 1rem 0; }
  a { color: #0071e3; text-decoration: none; }
  a:hover { text-decoration: underline; }
  code {
    background: #f5f5f7;
    padding: 0.15em 0.4em;
    border-radius: 4px;
    font-size: 0.9em;
    font-family: "SF Mono", Menlo, monospace;
  }
  pre {
    background: #f5f5f7;
    padding: 1rem;
    border-radius: 8px;
    overflow-x: auto;
    margin-bottom: 1rem;
  }
  pre code { background: none; padding: 0; }

  table {
    width: 100%;
    border-collapse: collapse;
    margin-bottom: 1rem;
    font-size: 0.95rem;
  }
  table th, table td {
    text-align: left;
    padding: 0.5rem 0.75rem;
    border: 1px solid #d2d2d7;
  }
  table th { background: #f5f5f7; font-weight: 600; }

  footer {
    margin-top: 3rem;
    padding-top: 1.5rem;
    border-top: 1px solid #d2d2d7;
    font-size: 0.85rem;
    color: #86868b;
    text-align: center;
  }
  @media (prefers-color-scheme: dark) {
    footer { border-top-color: #424245; }
  }
  footer a { color: inherit; text-decoration: none; }
  footer a:hover { text-decoration: underline; }
  footer .links { margin-top: 0.5rem; }
  footer .links a { margin: 0 0.75rem; }
</style>
</head>
<body>
"#;

const LANDING_PAGE_FOOT: &str = r#"
<footer>
  <p>&copy; 2025–2026 Juliette Pluto</p>
  <div class="links">
    <a href="https://github.com/jul-sh/clipkitty">GitHub</a>
    <a href="privacy.html">Privacy Policy</a>
    <a href="mailto:apple@jul.sh">Contact</a>
  </div>
</footer>

</body>
</html>
"#;
