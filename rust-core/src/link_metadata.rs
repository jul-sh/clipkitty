//! Link metadata fetching - extracts OG tags and images from URLs

use regex::Regex;
use std::time::Duration;

const FETCH_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_HTML_SIZE: usize = 512 * 1024; // 512KB max HTML
const MAX_IMAGE_SIZE: usize = 2 * 1024 * 1024; // 2MB max image

/// Fetched link metadata
pub struct LinkMetadata {
    pub title: Option<String>,
    pub image_data: Option<Vec<u8>>,
}

/// Fetch metadata from a URL (async)
pub async fn fetch_metadata(url: &str) -> Option<LinkMetadata> {
    let client = reqwest::Client::builder()
        .timeout(FETCH_TIMEOUT)
        .user_agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15")
        .build()
        .ok()?;

    // Fetch HTML
    let response = client.get(url).send().await.ok()?;
    if !response.status().is_success() {
        return None;
    }

    let html = response.text().await.ok()?;
    if html.len() > MAX_HTML_SIZE {
        return None;
    }

    // Extract OG tags
    let title = extract_og_tag(&html, "og:title")
        .or_else(|| extract_title_tag(&html));
    let image_url = extract_og_tag(&html, "og:image");

    // Fetch image if present
    let image_data = match image_url {
        Some(img_url) => {
            let img_url = resolve_url(url, &img_url)?;
            fetch_image(&client, &img_url).await
        }
        None => None,
    };

    Some(LinkMetadata { title, image_data })
}

fn extract_og_tag(html: &str, property: &str) -> Option<String> {
    // Match <meta property="og:..." content="...">
    let pattern = format!(
        r#"<meta[^>]*property=["']{}["'][^>]*content=["']([^"']+)["']"#,
        regex::escape(property)
    );
    let re = Regex::new(&pattern).ok()?;
    re.captures(html).map(|c| c[1].to_string())
        .or_else(|| {
            // Also try content before property
            let pattern = format!(
                r#"<meta[^>]*content=["']([^"']+)["'][^>]*property=["']{}["']"#,
                regex::escape(property)
            );
            let re = Regex::new(&pattern).ok()?;
            re.captures(html).map(|c| c[1].to_string())
        })
}

fn extract_title_tag(html: &str) -> Option<String> {
    let re = Regex::new(r"<title[^>]*>([^<]+)</title>").ok()?;
    re.captures(html).map(|c| c[1].trim().to_string())
}

fn resolve_url(base: &str, relative: &str) -> Option<String> {
    if relative.starts_with("http://") || relative.starts_with("https://") {
        return Some(relative.to_string());
    }
    if relative.starts_with("//") {
        return Some(format!("https:{}", relative));
    }
    url::Url::parse(base)
        .ok()?
        .join(relative)
        .ok()
        .map(|u| u.to_string())
}

async fn fetch_image(client: &reqwest::Client, url: &str) -> Option<Vec<u8>> {
    let response = client.get(url).send().await.ok()?;
    if !response.status().is_success() {
        return None;
    }

    let bytes = response.bytes().await.ok()?;
    if bytes.len() > MAX_IMAGE_SIZE {
        return None;
    }

    Some(bytes.to_vec())
}
