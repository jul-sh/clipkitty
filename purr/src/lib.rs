//! ClipKitty UniFFI wrapper over `purr-core`, with optional sync integration.

pub mod interface;
mod save_service;
mod store;
#[cfg(feature = "sync")]
mod sync_adapter;
#[cfg(feature = "sync")]
mod sync_db;

pub use purr_core::{
    benchmark_fixture, content_detection, database, indexer, match_presentation, models, ranking,
    search, search_service,
};
#[allow(unused_imports)]
pub use interface::*;
pub use store::{inspect_store_bootstrap, ClipboardStore, SearchOperation};

uniffi::setup_scaffolding!("purr");
