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
}

impl SearchCandidate {
    pub fn new(id: i64, content: String, timestamp: i64, tantivy_score: f32) -> Self {
        Self {
            id,
            content,
            timestamp,
            tantivy_score,
        }
    }

    pub fn content(&self) -> &str {
        &self.content
    }
}

/// Candidate with cached tokenization for lazy highlighting.
/// Content and tokenized words are preserved so highlighting can happen
/// after collection without re-tokenizing.
#[derive(Debug, Clone)]
pub struct ScoredCandidate {
    pub id: i64,
    pub content: String,
    pub timestamp: i64,
    pub tantivy_score: f32,
    /// Cached tokenized words from content: (char_start, char_end, word_lowercase)
    pub doc_words: Vec<(usize, usize, String)>,
}
