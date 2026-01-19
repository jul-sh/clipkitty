//! ClipKitty Core - Rust business logic for clipboard management
//!
//! This library implements the core business logic for the ClipKitty clipboard manager,
//! following the "ID Map & Hydration" pattern for efficient search at scale.
//!
//! # Architecture
//! - `models`: Data models (ClipboardContent, ClipboardItem, etc.)
//! - `database`: SQLite database with FTS5 trigram search
//! - `search`: Search engine with ID Map & Hydration pattern
//! - `content_detection`: Automatic content type detection
//! - `store`: Main API for Swift interop via UniFFI

mod content_detection;
mod database;
mod indexer;
mod models;
mod search;
mod store;

pub use content_detection::{detect_content, detect_content_type, is_url};
pub use models::*;
pub use store::*;

/// Get highlight ranges for a query in text
/// Returns vector of [start, length] pairs
pub fn highlight_ranges(text: String, query: String) -> Vec<Vec<u64>> {
    if query.is_empty() {
        return Vec::new();
    }

    let mut ranges: Vec<Vec<u64>> = Vec::new();
    let text_lower = text.to_lowercase();
    let query_lower = query.to_lowercase();

    // Try exact substring match first
    let mut start = 0;
    while let Some(pos) = text_lower[start..].find(&query_lower) {
        let abs_pos = start + pos;
        ranges.push(vec![abs_pos as u64, query.len() as u64]);
        start = abs_pos + 1;
        if ranges.len() >= 100 {
            break;
        }
    }

    // If no exact matches and query is long enough, try trigram matching
    if ranges.is_empty() && query.len() >= 3 {
        let chars: Vec<char> = query_lower.chars().collect();
        for i in 0..chars.len().saturating_sub(2) {
            let trigram: String = chars[i..i + 3].iter().collect();
            start = 0;
            while let Some(pos) = text_lower[start..].find(&trigram) {
                let abs_pos = start + pos;
                // Check for overlaps
                let overlaps = ranges
                    .iter()
                    .any(|r| abs_pos < (r[0] as usize + r[1] as usize) && abs_pos + 3 > r[0] as usize);
                if !overlaps {
                    ranges.push(vec![abs_pos as u64, 3]);
                }
                start = abs_pos + 1;
                if ranges.len() >= 100 {
                    break;
                }
            }
        }
    }

    // Sort by position
    ranges.sort_by_key(|r| r[0]);
    ranges
}

uniffi::include_scaffolding!("clipkitty_core");
