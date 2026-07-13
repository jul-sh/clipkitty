//! `clipkitty site` — public-site asset generation.
//!
//! `icon` exports the AppIcon bundle to PNG. `landing-page` renders README.md
//! to HTML via `cmark-gfm`. Both are thin wrappers around host tools; the CLI
//! exists to centralise pathing, dry-run, and env checks.

use std::io::{self, Write};

use anyhow::{anyhow, Result};
use camino::Utf8PathBuf;

use crate::cli::{SiteCmd, SiteRenderTarget};
use crate::icon::{render_app_icon, AppIconRenderTarget};
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

fn icon(repo: &RepoRoot, dry_run: bool, reporter: &Reporter) -> Result<()> {
    render_app_icon(repo, AppIconRenderTarget::PublicSite, dry_run, reporter)
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
    let body = body
        .replace(
            "https://raw.githubusercontent.com/jul-sh/clipkitty/main/Sources/MacApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
            "icon.png",
        )
        .replace("<h2>Why ClipKitty</h2>", "<h2 id=\"why-clipkitty\">Why ClipKitty</h2>")
        .replace("<h2>Features</h2>", "<h2 id=\"features\">Features</h2>")
        .replace("<h2>Installation</h2>", "<h2 id=\"installation\">Installation</h2>")
        .replace("<h2>Alternatives</h2>", "<h2 id=\"alternatives\">Alternatives</h2>")
        .replace("<h2>Behind the Scenes</h2>", "<h2 id=\"behind-the-scenes\">Behind the Scenes</h2>");

    let mut stdout = io::stdout().lock();
    stdout.write_all(LANDING_PAGE_HEAD.as_bytes())?;
    stdout.write_all(body.as_bytes())?;
    stdout.write_all(LANDING_PAGE_FOOT.as_bytes())?;
    Ok(())
}

const LANDING_PAGE_HEAD: &str = r##"<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ClipKitty — Clipboard Manager for macOS</title>
<meta name="description" content="Unlimited clipboard history with instant fuzzy search and multi-line previews. Private, fast, keyboard-driven. Free and open source for macOS.">
<meta name="theme-color" content="#fbfaf8" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#111216" media="(prefers-color-scheme: dark)">
<link rel="icon" href="icon.png">
<link rel="stylesheet" href="site.css">
</head>
<body>
<nav class="site-nav" aria-label="Primary">
  <a class="brand" href="./"><img src="icon.png" alt="">ClipKitty</a>
  <div class="nav-links">
    <a href="#features">Features</a>
    <a href="#installation">Download</a>
    <a href="https://github.com/jul-sh/clipkitty">GitHub</a>
  </div>
</nav>
<main>
"##;

const LANDING_PAGE_FOOT: &str = r##"
</main>
<footer>
  <div class="footer-inner">
    <p>&copy; 2025–2026 Juliette Pluto</p>
    <div class="footer-links">
      <a href="https://github.com/jul-sh/clipkitty">GitHub</a>
      <a href="privacy.html">Privacy</a>
      <a href="mailto:apple@jul.sh">Contact</a>
    </div>
  </div>
</footer>

</body>
</html>
"##;
