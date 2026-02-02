//! ClipKitty Core - Rust business logic for clipboard management
//!
//! This library implements the core business logic for the ClipKitty clipboard manager,
//! with efficient search using Tantivy (trigram retrieval) + Nucleo (fuzzy precision).
//!
//! Types are exported via UniFFI proc-macros (#[derive(uniffi::Record/Enum)]).

mod content_detection;
mod database;
mod indexer;
mod models;
mod search;
mod store;

// Internal use only - not exposed via FFI
pub(crate) use content_detection::detect_content;
pub use models::*;
pub use store::*;

// FFI-exported free function
#[uniffi::export]
pub fn is_url(text: String) -> bool {
    content_detection::is_url(text)
}

uniffi::setup_scaffolding!();
