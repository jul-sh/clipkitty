//! Search candidates and match contexts returned from Tantivy.

use std::sync::Arc;

#[derive(Debug, Clone)]
pub struct WholeItemMatchContext {
    content: Arc<str>,
    parent_len: usize,
}

impl WholeItemMatchContext {
    pub fn new(content: Arc<str>, parent_len: usize) -> Self {
        Self {
            content,
            parent_len,
        }
    }

    pub fn content(&self) -> &str {
        &self.content
    }

    pub fn parent_len(&self) -> usize {
        self.parent_len
    }
}

#[derive(Debug, Clone)]
pub struct ChunkMatchContext {
    content: Arc<str>,
    parent_len: usize,
    chunk_index: u32,
    chunk_start: usize,
    chunk_end: usize,
}

impl ChunkMatchContext {
    pub fn new(
        content: Arc<str>,
        parent_len: usize,
        chunk_index: u32,
        chunk_start: usize,
        chunk_end: usize,
    ) -> Self {
        Self {
            content,
            parent_len,
            chunk_index,
            chunk_start,
            chunk_end,
        }
    }

    pub fn content(&self) -> &str {
        &self.content
    }

    pub fn parent_len(&self) -> usize {
        self.parent_len
    }

    pub fn chunk_index(&self) -> u32 {
        self.chunk_index
    }

    pub fn chunk_start(&self) -> usize {
        self.chunk_start
    }

    pub fn chunk_end(&self) -> usize {
        self.chunk_end
    }
}

#[derive(Debug, Clone)]
pub enum SearchMatchContext {
    WholeItem(WholeItemMatchContext),
    Chunk(ChunkMatchContext),
}

impl SearchMatchContext {
    pub fn content(&self) -> &str {
        match self {
            Self::WholeItem(ctx) => ctx.content(),
            Self::Chunk(ctx) => ctx.content(),
        }
    }

    pub fn parent_len(&self) -> usize {
        match self {
            Self::WholeItem(ctx) => ctx.parent_len(),
            Self::Chunk(ctx) => ctx.parent_len(),
        }
    }

    pub fn chunk_range(&self) -> Option<(usize, usize)> {
        match self {
            Self::WholeItem(_) => None,
            Self::Chunk(ctx) => Some((ctx.chunk_start(), ctx.chunk_end())),
        }
    }

    pub fn chunk_index(&self) -> Option<u32> {
        match self {
            Self::WholeItem(_) => None,
            Self::Chunk(ctx) => Some(ctx.chunk_index()),
        }
    }
}

/// Whether a candidate was fully scored in Phase 2 or only had Phase 1 recall.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScoringPhase {
    /// Went through full Phase 2 bucket re-ranking.
    PhaseTwoScored,
    /// Only appeared in Phase 1 recall (tail candidate).
    PhaseOneOnly,
}

/// An item-level search candidate produced after collapsing matching units.
#[derive(Debug, Clone)]
pub struct SearchCandidate {
    pub id: i64,
    pub timestamp: i64,
    /// Structured Phase 1 score (word matches, proximity, recency, BM25).
    pub(crate) phase_one_score: crate::search_admission::PhaseOneBlendedScore,
    match_context: SearchMatchContext,
    scoring_phase: ScoringPhase,
}

impl SearchCandidate {
    pub(crate) fn new(
        id: i64,
        timestamp: i64,
        phase_one_score: crate::search_admission::PhaseOneBlendedScore,
        match_context: SearchMatchContext,
    ) -> Self {
        Self {
            id,
            timestamp,
            phase_one_score,
            match_context,
            scoring_phase: ScoringPhase::PhaseOneOnly,
        }
    }

    pub fn scoring_phase(&self) -> ScoringPhase {
        self.scoring_phase
    }

    pub fn set_scoring_phase(&mut self, phase: ScoringPhase) {
        self.scoring_phase = phase;
    }

    pub fn word_match_count(&self) -> u32 {
        self.phase_one_score.word_match_count
    }

    pub fn content(&self) -> &str {
        self.match_context.content()
    }

    pub fn parent_len(&self) -> usize {
        self.match_context.parent_len()
    }

    pub fn match_context(&self) -> &SearchMatchContext {
        &self.match_context
    }
}
