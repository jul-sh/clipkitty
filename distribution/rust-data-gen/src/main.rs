//! Synthetic clipboard data generator using Gemini API
//!
//! Rebuild of generate.mjs in Rust, utilizing the real ClipboardStore.
//! Generates data directly into a SQLite database.
//!
//! Build with: cargo build
//! Run with: cargo run

use anyhow::{Context, Result};
use chrono::Utc;
use clap::Parser;
use purr::{ClipboardStore, ClipboardStoreApi};
use purr::content_detection::parse_color_to_rgba;
use futures::StreamExt;
use image::GenericImageView;
use indicatif::{ProgressBar, ProgressStyle};
use rand::prelude::*;
use rand::rngs::StdRng;
use rusqlite::params;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::hash_map::DefaultHasher;
use std::fs;
use std::hash::{Hash, Hasher};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use tokio::sync::Semaphore;

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    /// Number of items to generate (overrides taxonomy.json if provided)
    #[arg(short, long)]
    count: Option<usize>,

    /// Gemini API Key (defaults to GEMINI_API_KEY env var)
    #[arg(short, long)]
    api_key: Option<String>,

    /// Concurrency limit
    #[arg(short = 'C', long, default_value_t = 10)]
    concurrency: usize,

    /// Path to save the SQLite database
    #[arg(short, long, default_value = "SyntheticData.sqlite")]
    db_path: String,

    /// Add specific items for the video demo
    #[arg(long)]
    demo: bool,

    /// Only insert demo items (skip AI generation, requires existing db)
    #[arg(long)]
    demo_only: bool,

    /// Reclassify text items as colors if they match color patterns
    #[arg(long)]
    reclassify_colors: bool,
}

// ─────────────────────────────────────────────────────────────────────────────
// DATA GENERATION HELPERS (self-contained, no feature flags needed in core)
// ─────────────────────────────────────────────────────────────────────────────



/// Generate a WebP thumbnail from image data
fn generate_thumbnail(image_data: &[u8], max_size: u32) -> Option<Vec<u8>> {
    let img = image::load_from_memory(image_data).ok()?;
    let (width, height) = img.dimensions();

    // Only create thumbnail if image is larger than max_size
    if width <= max_size && height <= max_size {
        // Image is small enough, just re-encode it as WebP
        let mut buf = Vec::new();
        let mut cursor = std::io::Cursor::new(&mut buf);
        img.write_to(&mut cursor, image::ImageFormat::WebP).ok()?;
        return Some(buf);
    }

    // Calculate new dimensions maintaining aspect ratio
    let scale = max_size as f32 / width.max(height) as f32;
    let new_width = (width as f32 * scale) as u32;
    let new_height = (height as f32 * scale) as u32;

    let thumbnail = img.thumbnail(new_width, new_height);

    let mut buf = Vec::new();
    let mut cursor = std::io::Cursor::new(&mut buf);
    thumbnail.write_to(&mut cursor, image::ImageFormat::WebP).ok()?;

    Some(buf)
}

/// Set item timestamp directly via SQL (for synthetic data generation)
fn set_timestamp_direct(db_path: &str, item_id: i64, timestamp_unix: i64) -> Result<()> {
    let conn = rusqlite::Connection::open(db_path)?;
    let timestamp = chrono::DateTime::from_timestamp(timestamp_unix, 0)
        .unwrap_or_else(|| chrono::Utc::now());
    let timestamp_str = timestamp.format("%Y-%m-%d %H:%M:%S%.f").to_string();
    conn.execute(
        "UPDATE items SET timestamp = ?1 WHERE id = ?2",
        params![timestamp_str, item_id],
    )?;
    Ok(())
}

/// Compress an image file to HEIC format using macOS `sips`.
/// Resizes so the longest side is at most `max_dimension` pixels.
fn compress_to_heic(image_path: &std::path::Path, max_dimension: u32, quality: u32) -> Option<Vec<u8>> {
    let temp_output = std::env::temp_dir().join("clipkitty_heic_temp.heic");

    let output = std::process::Command::new("sips")
        .args([
            "-s", "format", "heic",
            "-s", "formatOptions", &quality.to_string(),
            "-Z", &max_dimension.to_string(),
        ])
        .arg(image_path)
        .args(["--out"])
        .arg(&temp_output)
        .output()
        .ok()?;

    if !output.status.success() {
        eprintln!("sips failed: {}", String::from_utf8_lossy(&output.stderr));
        return None;
    }

    let data = fs::read(&temp_output).ok()?;
    let _ = fs::remove_file(&temp_output);
    Some(data)
}

/// Save an image item directly via SQL (for synthetic data generation).
/// Inserts into both `items` and `image_items` (normalized schema).
/// If `thumbnail` is None, one is generated from `image_data` (requires a format
/// the `image` crate can decode — not HEIC).
fn save_image_direct(
    db_path: &str,
    image_data: Vec<u8>,
    thumbnail: Option<Vec<u8>>,
    description: String,
    source_app: Option<String>,
    source_app_bundle_id: Option<String>,
) -> Result<i64> {
    let conn = rusqlite::Connection::open(db_path)?;
    let now = chrono::Utc::now();
    let timestamp_str = now.format("%Y-%m-%d %H:%M:%S%.f").to_string();

    let hash_input = format!("{}{}", description, image_data.len());
    let mut hasher = DefaultHasher::new();
    hash_input.hash(&mut hasher);
    let content_hash = hasher.finish().to_string();
    let thumbnail = thumbnail.or_else(|| generate_thumbnail(&image_data, 64));

    let tx = conn.unchecked_transaction()?;

    tx.execute(
        r#"INSERT INTO items (contentType, contentHash, content, timestamp, sourceApp, sourceAppBundleId, thumbnail)
           VALUES ('image', ?1, ?2, ?3, ?4, ?5, ?6)"#,
        params![
            content_hash,
            description,
            timestamp_str,
            source_app,
            source_app_bundle_id,
            thumbnail,
        ],
    )?;
    let item_id = tx.last_insert_rowid();

    tx.execute(
        "INSERT INTO image_items (itemId, data, description) VALUES (?1, ?2, ?3)",
        params![item_id, image_data, description],
    )?;

    tx.commit()?;
    Ok(item_id)
}

#[derive(Debug, Deserialize, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct AppInfo {
    name: String,
    bundle_id: String,
    weight: u32,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
struct LengthRange {
    lines: [usize; 2],
    chars: [usize; 2],
    weight: u32,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
struct CategoryInfo {
    #[serde(rename = "type")]
    category_type: String,
    weight: u32,
    apps: Vec<String>,
    description: String,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
struct LengthDistribution {
    short: LengthRange,
    medium: LengthRange,
    long: LengthRange,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Taxonomy {
    apps: Vec<AppInfo>,
    length_distribution: LengthDistribution,
    categories: Vec<CategoryInfo>,
    total_items: usize,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
struct GeminiResponse {
    items: Vec<String>,
}

async fn call_gemini(api_key: &str, prompt: &str) -> Result<Vec<String>> {
    let url = format!(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-exp:generateContent?key={}",
        api_key
    );

    let schema = schemars::schema_for!(GeminiResponse);
    let mut schema_json = serde_json::to_value(schema)?;
    if let Some(obj) = schema_json.as_object_mut() {
        obj.remove("$schema");
    }

    let request_body = json!({
        "contents": [{ "parts": [{ "text": prompt }] }],
        "generationConfig": {
            "responseMimeType": "application/json",
            "responseSchema": schema_json,
            "temperature": 1.5,
            "maxOutputTokens": 8192,
        }
    });

    let client = reqwest::Client::new();
    let response = client
        .post(&url)
        .json(&request_body)
        .send()
        .await?;

    let status = response.status();
    if !status.is_success() {
        let err_text = response.text().await?;
        return Err(anyhow::anyhow!("Gemini API error ({}): {}", status, err_text));
    }

    let resp_text = response.text().await?;
    let res_json: serde_json::Value = serde_json::from_str(&resp_text).context("Failed to parse outer JSON")?;
    let text = res_json["candidates"][0]["content"]["parts"][0]["text"]
        .as_str()
        .context("Missing text in Gemini response candidate")?;

    let gemini_res: GeminiResponse = serde_json::from_str(text).context("Failed to parse inner responseSchema JSON")?;
    Ok(gemini_res.items)
}

fn pick_weighted<'a, T, F>(items: &'a [T], weight_fn: F) -> &'a T
where F: Fn(&T) -> u32 {
    let total_weight: u32 = items.iter().map(&weight_fn).sum();
    let mut rng = rand::thread_rng();
    let mut r = rng.gen_range(0..total_weight.max(1));
    for item in items {
        let w = weight_fn(item);
        if r < w { return item; }
        r -= w;
    }
    items.first().expect("Empty collection")
}

fn build_prompt(category: &CategoryInfo, length_tier: &str, count: usize) -> String {
    let guidance = match length_tier {
        "short" => "1-4 lines, 50-200 chars. Brief snippets.",
        "medium" => "5-15 lines, 200-800 chars. Substantial context.",
        "long" => "30-80 lines, 1500-4000 chars. Detailed content.",
        _ => "",
    };

    format!(
        "Generate exactly {} unique clipboard items of type \"{}\".\nCategory: {}\nLength: {}\nRequirements:\n- UNIQUE and REALISTIC\n- Proper formatting\n- JSON ONLY, no markdown fences",
        count, category.category_type, category.description, guidance
    )
}

/// Generate a deterministic timestamp based on item index.
/// Distribution: exponential decay - many recent items, very few old (up to 24 months).
/// Uses seeded RNG for reproducibility.
fn generate_timestamp(item_index: usize, now: i64) -> i64 {
    const MAX_AGE_SECONDS: i64 = 24 * 30 * 24 * 60 * 60; // ~24 months
    const SEED: u64 = 0xC11B0A8D;

    // Create deterministic RNG from seed + item index
    let mut rng = StdRng::seed_from_u64(SEED.wrapping_add(item_index as u64));

    // Exponential distribution: -ln(U) / lambda
    // lambda controls the decay rate - higher = more recent items
    // With lambda = 4.0 / MAX_AGE, ~98% of items are in the first half of the range
    let lambda = 4.0 / MAX_AGE_SECONDS as f64;
    let u: f64 = rng.gen_range(0.0001..1.0); // Avoid ln(0)
    let age_seconds = (-u.ln() / lambda).min(MAX_AGE_SECONDS as f64) as i64;

    now - age_seconds
}

mod demo_data;
use demo_data::DEMO_ITEMS;

/// Find item ID by content hash (for setting timestamps on duplicates)
fn find_id_by_hash(db_path: &str, content_hash: &str) -> Option<i64> {
    let conn = rusqlite::Connection::open(db_path).ok()?;
    conn.query_row(
        "SELECT id FROM items WHERE contentHash = ?1",
        params![content_hash],
        |row| row.get(0),
    ).ok()
}

fn insert_demo_items(store: &ClipboardStore, db_path: &str) -> Result<()> {
    let now = Utc::now().timestamp();

    for item in DEMO_ITEMS {
        let _ = store.save_text(
            item.content.to_string(),
            Some(item.source_app.to_string()),
            Some(item.bundle_id.to_string()),
        );
        // Always set the correct timestamp (handles both new and duplicate items)
        let mut hasher = DefaultHasher::new();
        item.content.hash(&mut hasher);
        let content_hash = hasher.finish().to_string();
        if let Some(id) = find_id_by_hash(db_path, &content_hash) {
            let _ = set_timestamp_direct(db_path, id, now + item.offset);
        }
    }

    // Add kitty image (most recent item)
    let base_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let kitty_path = base_path.join("../../marketing/assets/kitty.jpg");
    if let Ok(raw_data) = fs::read(&kitty_path) {
        let thumbnail = generate_thumbnail(&raw_data, 64);
        let image_data = compress_to_heic(&kitty_path, 1500, 60).unwrap_or(raw_data);
        if let Ok(id) = save_image_direct(
            db_path,
            image_data,
            thumbnail,
            "cat, kitten, tabby, pet, animal, fur, whiskers".to_string(),
            Some("Photos".to_string()),
            Some("com.apple.Photos".to_string()),
        ) {
            if id > 0 {
                let _ = set_timestamp_direct(db_path, id, now - 5); // Most recent demo item
            }
        }
    }

    // Add source images with keyword captions (mirrors Vision framework output)
    // Images are compressed to HEIC (like the app does) to keep the DB small.
    let source_images_dir = base_path.join("../source-images");
    let source_images: &[(&str, &str, &str, &str, i64)] = &[
        // (filename, keywords, source_app, bundle_id, time_offset_seconds)
        (
            "[Advent Bay, Spitzbergen, Norway].webp",
            "landscape, arctic, mountains, bay, tundra, cabin, norway, spitzbergen, photograph, vintage",
            "Safari", "com.apple.Safari", -7200,
        ),
        (
            "At the French Windows. The Artist's Wife.webp",
            "painting, woman, portrait, garden, balcony, dress, spring, blossoms, trees, oil painting",
            "Photos", "com.apple.Photos", -6800,
        ),
        (
            "Bemberg Fondation Toulouse.jpg",
            "painting, impressionist, pointillism, garden, blossoms, trees, gate, spring, colorful, oil painting",
            "Safari", "com.apple.Safari", -6400,
        ),
        (
            "Eide : Granvin DATE ca. 1910.webp",
            "village, norway, fjord, harbor, boats, houses, mountains, coastal, photograph, vintage",
            "Photos", "com.apple.Photos", -6000,
        ),
        (
            "Gathering Autumn Flowers A1758.jpg",
            "painting, field, meadow, women, parasol, flowers, autumn, sky, clouds, impressionist",
            "Safari", "com.apple.Safari", -5600,
        ),
        (
            "Henri-Edmond Cross\u{a0}.jpg",
            "painting, pointillism, sunset, clouds, pink, sky, trees, landscape, neo-impressionist, oil painting",
            "Photos", "com.apple.Photos", -5200,
        ),
        (
            "Man with rickshaw on tall tree lined dirt road.webp",
            "photograph, road, trees, rickshaw, path, forest, tall trees, japan, vintage, black and white",
            "Safari", "com.apple.Safari", -4800,
        ),
        (
            "Miniature from an Akbarnama (detail) of Akbar wearing a bandhan\u{12b} patk\u{101} over a gold-brocaded silk sash.jpg.webp",
            "painting, miniature, mughal, emperor, akbar, throne, court, gold, turban, manuscript",
            "Safari", "com.apple.Safari", -4400,
        ),
        (
            "Monet - The Gare Saint-Lazare.jpg",
            "painting, monet, train station, steam, locomotive, impressionist, paris, railway, smoke, oil painting",
            "Photos", "com.apple.Photos", -4000,
        ),
        (
            "The Drunkard\u{2019}s Children (Plate 1).webp",
            "print, engraving, crowd, victorian, street scene, people, illustration, cruikshank, vintage, black and white",
            "Safari", "com.apple.Safari", -3600,
        ),
        (
            "The Great Wave off Kanagawa.jpg",
            "woodblock print, wave, ocean, hokusai, japan, mount fuji, boats, ukiyo-e, blue, sea",
            "Photos", "com.apple.Photos", -3200,
        ),
        (
            "The Solfatara, and the issue of hot vapours from underground lakes.webp",
            "illustration, volcano, landscape, geological, lake, steam, fire, figure, tree, scientific",
            "Safari", "com.apple.Safari", -2800,
        ),
        (
            "The Whale Car Wash, Oklahoma City, Oklahoma.webp",
            "photograph, whale, building, roadside, blue, car wash, americana, kitsch, architecture, vintage",
            "Photos", "com.apple.Photos", -2400,
        ),
    ];

    for (filename, keywords, source_app, bundle_id, offset) in source_images {
        let image_path = source_images_dir.join(filename);
        if let Ok(raw_data) = fs::read(&image_path) {
            // Generate thumbnail from original data (image crate can't decode HEIC)
            let thumbnail = generate_thumbnail(&raw_data, 64);
            // Compress to HEIC using macOS sips, falling back to raw data
            let image_data = compress_to_heic(&image_path, 1500, 60).unwrap_or(raw_data);
            if let Ok(id) = save_image_direct(
                db_path,
                image_data,
                thumbnail,
                keywords.to_string(),
                Some(source_app.to_string()),
                Some(bundle_id.to_string()),
            ) {
                if id > 0 {
                    let _ = set_timestamp_direct(db_path, id, now + offset);
                }
            }
        } else {
            eprintln!("Warning: source image not found: {}", filename);
        }
    }

    Ok(())
}

/// Reclassify text items as colors if they match color patterns.
/// Iterates over all items with contentType='text' and updates them
/// to contentType='color' with the parsed colorRgba if they're valid colors.
/// The text_items row stays as-is (colors use the same child table).
fn reclassify_colors(db_path: &str) -> Result<usize> {
    let conn = rusqlite::Connection::open(db_path)?;

    // Fetch all text items
    let mut stmt = conn.prepare(
        "SELECT id, content FROM items WHERE contentType = 'text'"
    )?;

    let text_items: Vec<(i64, String)> = stmt
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
        .collect::<Result<Vec<_>, _>>()?;

    let mut updated_count = 0;

    for (id, content) in text_items {
        // Check if this text is actually a color
        if let Some(rgba) = parse_color_to_rgba(&content) {
            conn.execute(
                "UPDATE items SET contentType = 'color', colorRgba = ?1 WHERE id = ?2",
                params![rgba, id],
            )?;
            updated_count += 1;
        }
    }

    Ok(updated_count)
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    let abs_db_path = std::env::current_dir()?.join(&args.db_path).to_str().unwrap().to_string();
    let store = Arc::new(ClipboardStore::new(abs_db_path.clone()).context("Failed to open database")?);

    // Demo-only mode: skip AI generation, just insert demo items
    if args.demo_only {
        println!("Inserting demo items only...");
        insert_demo_items(&store, &abs_db_path)?;
        println!("Demo items inserted.");
        return Ok(());
    }

    // Reclassify mode: iterate over text items and convert colors
    if args.reclassify_colors {
        println!("Reclassifying text items as colors...");
        let count = reclassify_colors(&abs_db_path)?;
        println!("Reclassified {} items as colors.", count);
        return Ok(());
    }

    let base_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let tax_path = base_path.join("../data-gen/taxonomy.json");
    let tax_str = fs::read_to_string(&tax_path).context("Failed to read taxonomy.json")?;
    let taxonomy: Taxonomy = serde_json::from_str(&tax_str)?;
    let target_total = args.count.unwrap_or(taxonomy.total_items);

    let pb = ProgressBar::new(target_total as u64);
    pb.set_style(ProgressStyle::default_bar()
        .template("{spinner:.green} [{elapsed_precise}] [{bar:40.cyan/blue}] {pos}/{len} ({eta}) {msg}")?
        .progress_chars("#>-"));

    let semaphore = Arc::new(Semaphore::new(args.concurrency));
    let api_key = Arc::new(args.api_key.or_else(|| std::env::var("GEMINI_API_KEY").ok()).context("Missing API Key")?);
    let taxonomy = Arc::new(taxonomy);
    let item_counter = Arc::new(AtomicUsize::new(0));
    let now = Utc::now().timestamp();

    let stream = futures::stream::unfold(0, |state| {
        if state >= target_total { return futures::future::ready(None); }
        let tier = pick_weighted(&[("short", 20), ("medium", 60), ("long", 20)], |i| i.1).0;
        let batch_size = match tier { "long" => 2, "medium" => 8, _ => 15 }.min(target_total - state);
        futures::future::ready(Some(((tier, batch_size), state + batch_size)))
    });

    let db_path_for_tasks = Arc::new(abs_db_path.clone());
    stream
        .map(|(tier, batch_size)| {
            let (sem, key, tax, st, bar, counter, db) = (
                semaphore.clone(),
                api_key.clone(),
                taxonomy.clone(),
                store.clone(),
                pb.clone(),
                item_counter.clone(),
                db_path_for_tasks.clone(),
            );
            let now = now;
            tokio::spawn(async move {
                let _permit = sem.acquire_owned().await.unwrap();
                let category = pick_weighted(&tax.categories, |c| c.weight);
                let prompt = build_prompt(category, tier, batch_size);

                match call_gemini(&key, &prompt).await {
                    Ok(items) => {
                        for content in items {
                            let valid_apps: Vec<_> = tax.apps.iter().filter(|a| category.apps.contains(&a.name)).collect();
                            let app = pick_weighted(&valid_apps, |a| a.weight);
                            if let Ok(id) = st.save_text(content, Some(app.name.clone()), Some(app.bundle_id.clone())) {
                                if id > 0 {
                                    let item_index = counter.fetch_add(1, Ordering::Relaxed);
                                    let timestamp = generate_timestamp(item_index, now);
                                    let _ = set_timestamp_direct(&db, id, timestamp);
                                    bar.inc(1);
                                    bar.set_message(format!("{} ({})", category.category_type, tier));
                                }
                            }
                        }
                    },
                    Err(e) => {
                        bar.println(format!("Gemini batch failed: {}", e));
                    }
                }
            })
        })
        .buffer_unordered(args.concurrency)
        .for_each(|_| futures::future::ready(()))
        .await;

    pb.finish_with_message("Generation complete");

    if args.demo {
        insert_demo_items(&store, &abs_db_path)?;
        pb.println("Demo items inserted.");
    }

    Ok(())
}
