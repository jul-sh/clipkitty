//! Utility functions for purr-sync.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

/// Compute a content hash from a string (DefaultHasher).
/// Duplicated from purr's StoredItem::hash_string to avoid reverse dependency.
pub fn content_hash(s: &str) -> String {
    let mut hasher = DefaultHasher::new();
    s.hash(&mut hasher);
    hasher.finish().to_string()
}
