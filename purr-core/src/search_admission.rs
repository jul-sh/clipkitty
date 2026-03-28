use crate::candidate::SearchCandidate;

pub const CHUNK_PARENT_THRESHOLD_BYTES: usize = 128 * 1024;
pub(crate) const PROXIMITY_BOOST_SCALE: f32 = 1000.0;
/// ConstScoreQuery signal added when any query word matches in content_words.
/// Chosen to be far above any realistic BM25 + proximity score so it can be
/// cleanly extracted without ambiguity.
pub(crate) const WORD_MATCH_SIGNAL: f32 = 100_000.0;

/// Structured Phase 1 score replacing the old magnitude-encoded f32.
///
/// Field order defines the lexicographic ranking policy via `derive(Ord)`:
/// 1. word_match_count — number of query words with exact word-level matches
/// 2. proximity_tier — number of adjacent query-word pairs found nearby
/// 3. recency_score — logarithmic recency decay (0-2550, scaled 10x from u8)
/// 4. bm25_remainder — BM25 score below the proximity band, quantized to u16
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct PhaseOneBlendedScore {
    pub word_match_count: u32,
    pub proximity_tier: u16,
    pub recency_score: u16,
    pub bm25_remainder: u16,
}

impl PhaseOneBlendedScore {
    /// Decode a raw Tantivy f32 score that carries magnitude-encoded signals:
    ///
    /// - **Word match count**: each matched query word adds [`WORD_MATCH_SIGNAL`]
    ///   (100 000) via `ConstScoreQuery` on `content_words`.
    /// - **Proximity tier**: each adjacent query-word pair found nearby adds
    ///   [`PROXIMITY_BOOST_SCALE`] (1 000) via `BoostQuery`.
    /// - **BM25 remainder**: whatever is left after stripping the above bands,
    ///   optionally reduced by a size penalty for large parents.
    ///
    /// Recency is computed independently from the timestamp.
    pub(crate) fn decode(raw_score: f32, timestamp: i64, parent_len: usize, now: i64) -> Self {
        let base = (raw_score as f64).max(0.001);

        let word_match_count = (base / WORD_MATCH_SIGNAL as f64).floor() as u32;
        let base = base - (word_match_count as f64 * WORD_MATCH_SIGNAL as f64);

        let proximity_tier = (base / PROXIMITY_BOOST_SCALE as f64).floor();
        let base_remainder = base - (proximity_tier * PROXIMITY_BOOST_SCALE as f64);
        let adjusted_remainder = if proximity_tier == 0.0 {
            (base_remainder - phase_one_size_penalty(parent_len)).max(0.0)
        } else {
            base_remainder
        };

        let recency_score = compute_recency(timestamp, now);

        Self {
            word_match_count,
            proximity_tier: proximity_tier as u16,
            recency_score: (recency_score * 10.0).round() as u16,
            bm25_remainder: (adjusted_remainder * 100.0)
                .round()
                .clamp(0.0, u16::MAX as f64) as u16,
        }
    }
}

/// Logarithmic recency curve: 0–255 range, decaying over ~400 hours.
fn compute_recency(timestamp: i64, now: i64) -> f64 {
    let age_secs = (now - timestamp).max(0) as f64;
    let k: f64 = 20.0;
    let max_hours: f64 = 400.0;
    let age_hours = age_secs / 3600.0;
    let denom = (1.0 + k * max_hours).ln();
    (255.0 * (1.0 - (1.0 + k * age_hours).ln() / denom)).max(0.0)
}

fn phase_one_size_penalty(parent_len: usize) -> f64 {
    match parent_len {
        0..=CHUNK_PARENT_THRESHOLD_BYTES => 0.0,
        ..=1_048_576 => 16.0,
        _ => 32.0,
    }
}

#[cfg(test)]
impl PhaseOneBlendedScore {
    /// Test convenience: create a score from just a raw f32 for tests that
    /// only care about relative ordering via bm25_remainder.
    pub(crate) fn from_raw(raw: f32) -> Self {
        Self {
            word_match_count: 0,
            proximity_tier: 0,
            recency_score: 0,
            bm25_remainder: raw.round().clamp(0.0, u16::MAX as f32) as u16,
        }
    }
}

pub(crate) struct PhaseOneAdmissionPolicy;

impl PhaseOneAdmissionPolicy {
    pub(crate) const REGULAR_HEAD_LIMIT: usize = 64;
    pub(crate) const LARGE_HEAD_LIMIT: usize = 8;
    pub(crate) const TOTAL_HEAD_LIMIT: usize = Self::REGULAR_HEAD_LIMIT + Self::LARGE_HEAD_LIMIT;

    pub(crate) fn is_large_parent(parent_len: usize) -> bool {
        parent_len > CHUNK_PARENT_THRESHOLD_BYTES
    }

    pub(crate) fn should_stop_recall(
        candidates: &[SearchCandidate],
        last_score: Option<PhaseOneBlendedScore>,
    ) -> bool {
        if candidates.len() < Self::TOTAL_HEAD_LIMIT {
            return false;
        }

        let Some(regular_threshold) = Self::regular_threshold(candidates) else {
            return false;
        };

        last_score.is_some_and(|s| s < regular_threshold)
    }

    pub(crate) fn select_phase_two_head(candidates: &[SearchCandidate]) -> PhaseTwoHead {
        let mut regular = Vec::new();
        let mut large = Vec::new();

        for (index, candidate) in candidates.iter().enumerate() {
            if Self::is_large_parent(candidate.parent_len()) {
                large.push(index);
            } else {
                regular.push(index);
            }
        }

        let mut indices = Vec::new();
        indices.extend(regular.iter().copied().take(Self::REGULAR_HEAD_LIMIT));

        if regular.len() >= Self::REGULAR_HEAD_LIMIT {
            let threshold = candidates[regular[Self::REGULAR_HEAD_LIMIT - 1]].phase_one_score;
            indices.extend(
                large
                    .iter()
                    .copied()
                    .filter(|&index| candidates[index].phase_one_score >= threshold)
                    .take(Self::LARGE_HEAD_LIMIT),
            );
        } else {
            indices.extend(
                large
                    .iter()
                    .copied()
                    .take(Self::TOTAL_HEAD_LIMIT.saturating_sub(indices.len())),
            );
        }

        PhaseTwoHead { indices }
    }

    fn regular_threshold(candidates: &[SearchCandidate]) -> Option<PhaseOneBlendedScore> {
        candidates
            .iter()
            .filter(|candidate| !Self::is_large_parent(candidate.parent_len()))
            .nth(Self::REGULAR_HEAD_LIMIT.saturating_sub(1))
            .map(|candidate| candidate.phase_one_score)
    }
}

pub(crate) struct PhaseTwoHead {
    indices: Vec<usize>,
}

impl PhaseTwoHead {
    pub(crate) fn into_indices(self) -> Vec<usize> {
        self.indices
    }
}
