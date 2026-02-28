//! ClipKitty Core - Rust business logic for clipboard management
//!
//! This library implements the core business logic for the ClipKitty clipboard manager,
//! with efficient search using Tantivy (trigram retrieval with phrase-boost scoring).
//!
//! Types are exported via UniFFI proc-macros (#[derive(uniffi::Record/Enum)]).

pub(crate) mod candidate;
pub mod content_detection;
pub mod database;
mod indexer;
pub mod interface;
pub mod models;
pub mod ranking;
pub mod search;
mod store;

pub use interface::*;
pub use store::ClipboardStore;

uniffi::setup_scaffolding!("purr");
