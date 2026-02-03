//! Synthetic clipboard data generator using Gemini API
//!
//! Rebuild of generate.mjs in Rust, utilizing the real ClipboardStore.
//! Generates data directly into a SQLite database.
//!
//! Requires the `data-gen` feature to be enabled.

use anyhow::{Context, Result};
use chrono::Utc;
use clap::Parser;
use clipkitty_core::{ClipboardStore, ClipboardStoreApi};
use clipkitty_core::content_detection::parse_color_to_rgba;
use futures::StreamExt;
use indicatif::{ProgressBar, ProgressStyle};
use rand::{Rng, SeedableRng};
use rand::rngs::StdRng;
use rusqlite::params;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::fs;
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

fn insert_demo_items(store: &ClipboardStore) -> Result<()> {
    let now = Utc::now().timestamp();
    let demo_items = vec![
        ("Apartment walkthrough notes: 437 Riverside Dr #12, hardwood floors throughout, south-facing windows with park views, original crown molding, in-unit washer/dryer, $2850/mo, super lives on-site, contact Marcus Realty about lease terms and move-in date flexibility...", "Notes", "com.apple.Notes", now - (180 * 24 * 60 * 60)),
        ("riverside_park_picnic_directions.txt", "Notes", "com.apple.Notes", now - 3600),
        ("river_animation_keyframes.css", "TextEdit", "com.apple.TextEdit", now - 3500),
        ("#7C3AED", "Freeform", "com.apple.freeform", now - 1800),
        ("#FF5733", "Freeform", "com.apple.freeform", now - 1700),
        ("#2DD4BF", "Preview", "com.apple.Preview", now - 1600),
        ("#F472B6", "Preview", "com.apple.Preview", now - 1500),
        ("Orange tabby cat sleeping on mechanical keyboard", "Photos", "com.apple.Photos", now - 1400),
        ("Hello ClipKitty!\n\n• Unlimited History\n• Instant Search\n• Private\n\nYour clipboard, supercharged.", "Notes", "com.apple.Notes", now - 600),
        ("Hello and welcome to the onboarding flow for new team members...", "Reminders", "com.apple.reminders", now - 500),
        ("hello_world.py", "Finder", "com.apple.finder", now - 400),
        ("sayHello(user: User) -> String { ... }", "Automator", "com.apple.Automator", now - 300),
        ("The quick brown fox jumps over the lazy dog", "Notes", "com.apple.Notes", now - 120),
        ("https://developer.apple.com/documentation/swiftui", "Safari", "com.apple.Safari", now - 60),
        ("sk-proj-Tj7X9...", "Passwords", "com.apple.Passwords", now - 30),
        ("SELECT users.name, orders.total FROM orders JOIN users ON users.id = orders.user_id WHERE orders.status = 'completed';", "Numbers", "com.apple.Numbers", now - 10),
    ];

    for (content, app, bundle, ts) in demo_items {
        if let Ok(id) = store.save_text(content.to_string(), Some(app.to_string()), Some(bundle.to_string())) {
            if id > 0 {
                let _ = store.set_timestamp(id, ts);
            }
        }
    }

    // Add kitty image (most recent item)
    let base_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let kitty_path = base_path.join("../marketing/assets/kitty.jpg");
    if let Ok(image_data) = fs::read(&kitty_path) {
        if let Ok(id) = store.save_image_with_description(
            image_data,
            "kitty".to_string(),
            Some("Photos".to_string()),
            Some("com.apple.Photos".to_string()),
        ) {
            if id > 0 {
                let _ = store.set_timestamp(id, now - 5); // Most recent demo item
            }
        }
    }

    Ok(())
}

/// Reclassify text items as colors if they match color patterns.
/// Iterates over all items with contentType='text' and updates them
/// to contentType='color' with the parsed colorRgba if they're valid colors.
fn reclassify_colors(db_path: &str) -> Result<usize> {
    let conn = rusqlite::Connection::open(db_path)?;

    // Fetch all text items
    let mut stmt = conn.prepare(
        "SELECT id, content FROM items WHERE contentType = 'text' OR contentType IS NULL"
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
        insert_demo_items(&store)?;
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
    let tax_path = base_path.join("../Scripts/data-gen/taxonomy.json");
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

    stream
        .map(|(tier, batch_size)| {
            let (sem, key, tax, st, bar, counter) = (
                semaphore.clone(),
                api_key.clone(),
                taxonomy.clone(),
                store.clone(),
                pb.clone(),
                item_counter.clone(),
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
                                    let _ = st.set_timestamp(id, timestamp);
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
        insert_demo_items(&store)?;
        pb.println("Demo items inserted.");
    }

    Ok(())
}
