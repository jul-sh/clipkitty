//! `clipkitty site` — public-site asset generation.
//!
//! `icon` exports the AppIcon bundle to PNG. `landing-page` renders README.md
//! to HTML via `cmark-gfm`. Both are thin wrappers around host tools; the CLI
//! exists to centralise pathing, dry-run, and env checks.

use std::{
    fs,
    io::{self, Write},
};

use anyhow::{anyhow, Context, Result};
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
    let template_path: Utf8PathBuf = repo.join("site/templates/index.html");

    if dry_run {
        reporter.info(&format!(
            "[dry-run] would render {readme} with {template_path} → stdout"
        ));
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

    let template = fs::read_to_string(template_path.as_std_path())
        .with_context(|| format!("reading landing-page template: {template_path}"))?;
    let page = render_landing_page(&template, &body)?;

    let mut stdout = io::stdout().lock();
    stdout.write_all(page.as_bytes())?;
    Ok(())
}

pub(crate) const README_CONTENT_MARKER: &str = "<!-- README_CONTENT -->";

fn render_landing_page(template: &str, body: &str) -> Result<String> {
    let marker_count = template.matches(README_CONTENT_MARKER).count();
    if marker_count != 1 {
        return Err(anyhow!(
            "landing-page template must contain {README_CONTENT_MARKER:?} exactly once; found {marker_count}"
        ));
    }
    Ok(template.replacen(README_CONTENT_MARKER, body, 1))
}

#[cfg(test)]
mod tests {
    use super::{render_landing_page, README_CONTENT_MARKER};

    #[test]
    fn landing_page_replaces_its_single_content_marker() {
        let rendered = render_landing_page(
            &format!("<main>{README_CONTENT_MARKER}</main>"),
            "<h1>ClipKitty</h1>",
        )
        .expect("valid landing template");

        assert_eq!(rendered, "<main><h1>ClipKitty</h1></main>");
    }

    #[test]
    fn landing_page_rejects_missing_or_duplicate_markers() {
        assert!(render_landing_page("<main></main>", "body").is_err());
        assert!(render_landing_page(
            &format!("{README_CONTENT_MARKER}{README_CONTENT_MARKER}"),
            "body"
        )
        .is_err());
    }
}
