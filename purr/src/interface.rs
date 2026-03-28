//! Public FFI-facing type exports for the `purr` wrapper crate.

pub use purr_core::interface::*;

#[cfg(feature = "sync")]
pub use purr_sync::{
    SyncApplyReport, SyncContentPayload, SyncLiveSnapshot, SyncRecordChange, SyncSnapshot,
    SyncTombstoneSnapshot, SyncVersion,
};
