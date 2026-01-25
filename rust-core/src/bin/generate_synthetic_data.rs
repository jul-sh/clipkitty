//! Synthetic clipboard data generator using Gemini API
//!
//! Rebuild of generate.mjs in Rust, utilizing the real ClipboardStore.
//! Generates data directly into a SQLite database.

use anyhow::{Context, Result};
use chrono::Utc;
use clap::Parser;
use clipkitty_core::ClipboardStore;
use futures::StreamExt;
use indicatif::{ProgressBar, ProgressStyle};
use rand::Rng;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
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
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    let base_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let tax_path = base_path.join("../Scripts/data-gen/taxonomy.json");
    let tax_str = fs::read_to_string(&tax_path).context("Failed to read taxonomy.json")?;
    let taxonomy: Taxonomy = serde_json::from_str(&tax_str)?;
    let target_total = args.count.unwrap_or(taxonomy.total_items);

    let abs_db_path = std::env::current_dir()?.join(&args.db_path).to_str().unwrap().to_string();
    let store = Arc::new(ClipboardStore::new(abs_db_path).context("Failed to open database")?);

    let pb = ProgressBar::new(target_total as u64);
    pb.set_style(ProgressStyle::default_bar()
        .template("{spinner:.green} [{elapsed_precise}] [{bar:40.cyan/blue}] {pos}/{len} ({eta}) {msg}")?
        .progress_chars("#>-"));

    let semaphore = Arc::new(Semaphore::new(args.concurrency));
    let api_key = Arc::new(args.api_key.or_else(|| std::env::var("GEMINI_API_KEY").ok()).context("Missing API Key")?);
    let taxonomy = Arc::new(taxonomy);

    let stream = futures::stream::unfold(0, |state| {
        if state >= target_total { return futures::future::ready(None); }
        let tier = pick_weighted(&[("short", 20), ("medium", 60), ("long", 20)], |i| i.1).0;
        let batch_size = match tier { "long" => 2, "medium" => 8, _ => 15 }.min(target_total - state);
        futures::future::ready(Some(((tier, batch_size), state + batch_size)))
    });

    stream
        .map(|(tier, batch_size)| {
            let (sem, key, tax, st, bar) = (semaphore.clone(), api_key.clone(), taxonomy.clone(), store.clone(), pb.clone());
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
                                    let now = Utc::now().timestamp();
                                    let mut rng = rand::thread_rng();
                                    // 18 months in seconds
                                    let eighteen_months_secs = 18 * 30 * 24 * 60 * 60;
                                    // Linear distribution over the last 18 months
                                    let random_ts = now - rng.gen_range(0..eighteen_months_secs);
                                    if st.set_timestamp(id, random_ts).is_ok() {
                                        bar.inc(1);
                                        bar.set_message(format!("{} ({})", category.category_type, tier));
                                    }
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
