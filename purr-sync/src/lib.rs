//! purr-sync — sync domain logic for ClipKitty.
//!
//! Event-sourced sync with per-domain version vectors, conflict resolution,
//! compaction, and replay. No dependency on the host crate (purr).

pub mod compactor;
pub mod error;
pub mod event;
pub mod projector;
pub mod replay;
pub mod schema;
pub mod snapshot;
pub mod store;
pub mod types;
pub mod util;

pub use error::{SyncError, SyncResult};
