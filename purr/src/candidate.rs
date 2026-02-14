//! Search candidate with memoized derived state.
//!
//! Module isolation ensures no code outside this module can mutate `content`
//! after construction, so the `OnceLock` caches can never go stale.

use std::sync::OnceLock;

/// A search candidate from Tantivy with memoized derived state.
/// `content_lower()` and `doc_words()` are computed on first access and cached,
/// avoiding redundant work across Phase 2 (ranking) and Phase 3 (highlighting).
#[derive(Debug, Clone)]
pub struct SearchCandidate {
    pub id: i64,
    content: String,
    pub timestamp: i64,
    /// Blended score (BM25 + recency) from Tantivy's tweak_score
    pub tantivy_score: f32,
    content_lower: OnceLock<String>,
    doc_words: OnceLock<Vec<(usize, usize, String)>>,
}

impl SearchCandidate {
    pub fn new(id: i64, content: String, timestamp: i64, tantivy_score: f32) -> Self {
        Self {
            id,
            content,
            timestamp,
            tantivy_score,
            content_lower: OnceLock::new(),
            doc_words: OnceLock::new(),
        }
    }

    pub fn content(&self) -> &str {
        &self.content
    }

    pub fn content_lower(&self) -> &str {
        self.content_lower.get_or_init(|| self.content.to_lowercase())
    }

    pub fn doc_words(&self) -> &[(usize, usize, String)] {
        self.doc_words.get_or_init(|| {
            crate::search::tokenize_words(self.content_lower())
        })
    }
}
