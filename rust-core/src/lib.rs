//! ClipKitty Core - Rust business logic for clipboard management
//!
//! This library implements the core business logic for the ClipKitty clipboard manager,
//! with efficient search using Tantivy (trigram retrieval) + Nucleo (fuzzy precision).
//!
//! Types are exported via UniFFI proc-macros (#[derive(uniffi::Record/Enum)]).

mod content_detection;
mod database;
mod indexer;
pub mod interface;
mod link_metadata;
mod models;
mod search;
mod store;

pub use interface::*;
pub use models::*;
pub use store::*;

uniffi::setup_scaffolding!();
