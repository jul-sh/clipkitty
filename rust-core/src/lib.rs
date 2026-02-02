//! ClipKitty Core - Rust business logic for clipboard management
//!
//! This library implements the core business logic for the ClipKitty clipboard manager,
//! with efficient search using Tantivy (trigram retrieval) + Nucleo (fuzzy precision).
//!
//! # Architecture
//! - `models`: Data models (ClipboardContent, ClipboardItem, ItemMetadata, etc.)
//! - `database`: SQLite database layer
//! - `indexer`: Tantivy trigram index
//! - `search`: Two-layer search engine with Nucleo
//! - `content_detection`: Automatic content type detection (URLs, colors, etc.)
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

uniffi::include_scaffolding!("clipkitty_core");
