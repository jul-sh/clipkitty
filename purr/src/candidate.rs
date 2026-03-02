//! Search candidate with encapsulated content.
//!
//! Module isolation ensures no code outside this module can mutate `content`
//! after construction.

/// A search candidate from Tantivy.
#[derive(Debug, Clone)]
pub struct SearchCandidate {
    pub id: i64,
    content: String,
    pub timestamp: i64,
    /// Blended score (BM25 + recency) from Tantivy's tweak_score
    pub tantivy_score: f32,
    /// Source app text from Tantivy (for metadata-match highlighting)
    pub source_app: String,
}

impl SearchCandidate {
    pub fn new(id: i64, content: String, timestamp: i64, tantivy_score: f32, source_app: String) -> Self {
        Self {
            id,
            content,
            timestamp,
            tantivy_score,
            source_app,
        }
    }

    pub fn content(&self) -> &str {
        &self.content
    }
}
