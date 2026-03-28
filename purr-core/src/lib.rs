//! ClipKitty core domain and storage/search logic without optional sync transport.

pub struct UniFfiTag;

pub mod benchmark_fixture;
pub(crate) mod candidate;
pub mod content_detection;
pub mod database;
pub mod indexer;
pub mod interface;
pub mod match_presentation;
pub mod models;
pub mod ranking;
pub mod save_service;
pub mod search;
pub(crate) mod search_admission;
pub mod search_result_builder;
pub mod search_service;

pub use interface::*;
