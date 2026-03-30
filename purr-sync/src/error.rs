//! Sync-specific error types.

/// Errors from sync operations.
#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error("SQLite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("Connection pool error: {0}")]
    Pool(#[from] r2d2::Error),
    #[error("Sync data inconsistency: {0}")]
    InconsistentData(String),
}

pub type SyncResult<T> = Result<T, SyncError>;
