//! Check that README feature copy stays aligned with App Store copy.

use std::fs;

use anyhow::{anyhow, bail, Context, Result};

use crate::output::Reporter;
use crate::process::Runner;
use crate::repo::RepoRoot;

const README_PATH: &str = "README.md";
const APP_STORE_DESCRIPTION_PATH: &str = "distribution/metadata/en-US/description.txt";
const APP_STORE_INTRO: &[&str] = &[
    "ClipKitty is built around a simple idea: your clipboard can remember more without asking more from you.",
];
const APP_STORE_BODY_EXCEPTIONS: &[&str] = &["Sync only when you want it", "Private by default"];

pub(crate) fn check_synced(repo: &RepoRoot, reporter: &Reporter) -> Result<()> {
    let readme = read_to_string(repo, README_PATH)?;
    let app_store = read_to_string(repo, APP_STORE_DESCRIPTION_PATH)?;
    check_alignment(&readme, &app_store)?;
    reporter.success("README and App Store feature copy are aligned.");
    Ok(())
}

pub(crate) fn check_staged_synced(repo: &RepoRoot, reporter: &Reporter) -> Result<()> {
    let readme = read_index_to_string(repo, reporter, README_PATH)?;
    let app_store = read_index_to_string(repo, reporter, APP_STORE_DESCRIPTION_PATH)?;
    check_alignment(&readme, &app_store)?;
    reporter.success("Staged README and App Store feature copy are aligned.");
    Ok(())
}

fn check_alignment(readme: &str, app_store: &str) -> Result<()> {
    let readme_features = parse_readme_features(readme)?;
    let app_store_description = parse_app_store_description(app_store)?;

    let mut errors = Vec::new();

    if app_store_description.intro != APP_STORE_INTRO {
        errors.push(format!(
            "{APP_STORE_DESCRIPTION_PATH}: intro must be exactly:\n{}",
            APP_STORE_INTRO.join("\n\n")
        ));
    }

    if app_store_description.features.len() != readme_features.len() {
        errors.push(format!(
            "{APP_STORE_DESCRIPTION_PATH}: expected {} feature(s), found {}",
            readme_features.len(),
            app_store_description.features.len()
        ));
    }

    for (index, readme_feature) in readme_features.iter().enumerate() {
        let Some(app_store_feature) = app_store_description.features.get(index) else {
            continue;
        };
        if app_store_feature.title != readme_feature.title {
            errors.push(format!(
                "{APP_STORE_DESCRIPTION_PATH}: feature {} title is `{}`, expected `{}`",
                index + 1,
                app_store_feature.title,
                readme_feature.title
            ));
            continue;
        }

        if APP_STORE_BODY_EXCEPTIONS.contains(&readme_feature.title.as_str()) {
            continue;
        }

        let expected = normalize_copy(&strip_markdown(&readme_feature.body));
        let actual = normalize_copy(&app_store_feature.body);
        if actual != expected {
            errors.push(format!(
                "{APP_STORE_DESCRIPTION_PATH}: `{}` body diverges from {README_PATH}",
                readme_feature.title
            ));
        }
    }

    if errors.is_empty() {
        return Ok(());
    }

    for error in &errors {
        eprintln!("{error}");
    }
    bail!(
        "README/App Store feature copy drift detected. Keep titles and non-sync/privacy feature bodies aligned."
    )
}

#[derive(Debug, PartialEq, Eq)]
struct Feature {
    title: String,
    body: String,
}

#[derive(Debug, PartialEq, Eq)]
struct AppStoreDescription {
    intro: Vec<String>,
    features: Vec<Feature>,
}

fn parse_readme_features(readme: &str) -> Result<Vec<Feature>> {
    let section = markdown_section(readme, "## Features")?;
    let mut features = Vec::new();

    for block in section.split("\n\n") {
        let block = block.trim();
        if block.is_empty() || block.starts_with("<!--") {
            continue;
        }
        let Some(rest) = block.strip_prefix("- **") else {
            continue;
        };
        let Some(title_end) = rest.find("**") else {
            return Err(anyhow!("{README_PATH}: malformed feature title `{block}`"));
        };
        let title = rest[..title_end].trim_end_matches(':').to_string();
        let body = rest[title_end + 2..]
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .collect::<Vec<_>>()
            .join(" ");
        if body.is_empty() {
            return Err(anyhow!("{README_PATH}: feature `{title}` has no body"));
        }
        features.push(Feature { title, body });
    }

    if features.is_empty() {
        return Err(anyhow!("{README_PATH}: no features found"));
    }
    Ok(features)
}

fn markdown_section<'a>(document: &'a str, heading: &str) -> Result<&'a str> {
    let Some(start) = document.find(heading) else {
        return Err(anyhow!("{README_PATH}: missing `{heading}` section"));
    };
    let content_start = start + heading.len();
    let content_start = document[content_start..]
        .strip_prefix("\n\n")
        .map(|_| content_start + 2)
        .unwrap_or(content_start);
    let next_heading = document[content_start..]
        .find("\n## ")
        .map(|offset| content_start + offset)
        .unwrap_or(document.len());
    Ok(&document[content_start..next_heading])
}

fn parse_app_store_description(contents: &str) -> Result<AppStoreDescription> {
    let sections: Vec<&str> = contents
        .trim()
        .split("\n\n")
        .map(str::trim)
        .filter(|section| !section.is_empty())
        .collect();

    if sections.len() < APP_STORE_INTRO.len() {
        return Err(anyhow!(
            "{APP_STORE_DESCRIPTION_PATH}: description is missing intro copy"
        ));
    }

    let intro = sections[..APP_STORE_INTRO.len()]
        .iter()
        .map(|section| (*section).to_string())
        .collect();
    let mut features = Vec::new();

    for section in &sections[APP_STORE_INTRO.len()..] {
        let mut lines = section
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty());
        let Some(title) = lines.next() else {
            continue;
        };
        let body = lines.collect::<Vec<_>>().join(" ");
        if body.is_empty() {
            return Err(anyhow!(
                "{APP_STORE_DESCRIPTION_PATH}: feature `{title}` has no body"
            ));
        }
        features.push(Feature {
            title: title.to_string(),
            body,
        });
    }

    Ok(AppStoreDescription { intro, features })
}

fn strip_markdown(input: &str) -> String {
    let without_bold = input.replace("**", "");
    strip_links(&without_bold)
}

fn strip_links(input: &str) -> String {
    let mut output = String::new();
    let mut cursor = 0;
    while let Some(open_bracket) = input[cursor..].find('[') {
        let open_bracket = cursor + open_bracket;
        let Some(close_bracket_offset) = input[open_bracket..].find(']') else {
            break;
        };
        let close_bracket = open_bracket + close_bracket_offset;
        let link_target_start = close_bracket + 1;
        if !input[link_target_start..].starts_with('(') {
            break;
        }
        let Some(close_paren_offset) = input[link_target_start + 1..].find(')') else {
            break;
        };
        let close_paren = link_target_start + 1 + close_paren_offset;
        output.push_str(&input[cursor..open_bracket]);
        output.push_str(&input[open_bracket + 1..close_bracket]);
        cursor = close_paren + 1;
    }
    output.push_str(&input[cursor..]);
    output
}

fn normalize_copy(input: &str) -> String {
    input.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn read_to_string(repo: &RepoRoot, rel: &str) -> Result<String> {
    let path = repo.join(rel);
    fs::read_to_string(path.as_std_path()).with_context(|| format!("reading {path}"))
}

fn read_index_to_string(repo: &RepoRoot, reporter: &Reporter, rel: &str) -> Result<String> {
    Runner::new(reporter, "git")
        .arg("show")
        .arg(format!(":{rel}"))
        .cwd(repo.as_path())
        .output()
        .with_context(|| format!("reading staged {rel}"))?
        .stdout_string()
        .with_context(|| format!("decoding staged {rel} as UTF-8"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_readme_feature_bullets() {
        let readme = "# App\n\n## Features\n\n- **Search:**\n  Find **things** quickly.\n\n- **Open source:**\n  You can [verify](VERIFY.md) builds.\n\n## Install\n";

        assert_eq!(
            parse_readme_features(readme).unwrap(),
            vec![
                Feature {
                    title: "Search".to_string(),
                    body: "Find **things** quickly.".to_string()
                },
                Feature {
                    title: "Open source".to_string(),
                    body: "You can [verify](VERIFY.md) builds.".to_string()
                }
            ]
        );
    }

    #[test]
    fn strips_markdown_for_app_store_comparison() {
        assert_eq!(
            strip_markdown("Press **⌥Space** and [verify](VERIFY.md)."),
            "Press ⌥Space and verify."
        );
    }

    #[test]
    fn permits_sync_and_privacy_body_exceptions() {
        let readme = "# App\n\n## Features\n\n- **Sync only when you want it**  \n  README sync copy.\n\n- **Private by default**  \n  README privacy copy.\n\n- **Search**  \n  Find clips quickly.\n\n## Install\n";
        let app_store = "ClipKitty is built around a simple idea: your clipboard can remember more without asking more from you.\n\nSync only when you want it\nApp Store sync copy.\n\nPrivate by default\nApp Store privacy copy.\n\nSearch\nFind clips quickly.\n";

        check_alignment(readme, app_store).unwrap();
    }

    #[test]
    fn rejects_non_exception_body_drift() {
        let readme =
            "# App\n\n## Features\n\n- **Search**  \n  Find clips quickly.\n\n## Install\n";
        let app_store = "ClipKitty is built around a simple idea: your clipboard can remember more without asking more from you.\n\nSearch\nDifferent copy.\n";

        assert!(check_alignment(readme, app_store).is_err());
    }
}
