//! ClipKitty Core - Rust business logic for clipboard management
//!
//! This library implements the core business logic for the ClipKitty clipboard manager,
//! with efficient search using Tantivy (trigram retrieval with phrase-boost scoring).
//!
//! Types are exported via UniFFI proc-macros (#[derive(uniffi::Record/Enum)]).

pub mod benchmark_fixture;
pub(crate) mod candidate;
pub mod content_detection;
pub mod database;
pub mod indexer;
pub mod interface;
pub(crate) mod match_presentation;
pub mod models;
pub mod ranking;
mod save_service;
pub mod search;
pub(crate) mod search_admission;
mod search_result_builder;
mod search_service;
mod store;
#[cfg(feature = "sync")]
pub(crate) mod sync_bridge;

pub use interface::*;
pub use store::{inspect_store_bootstrap, ClipboardStore, SearchOperation};

uniffi::setup_scaffolding!("purr");
