use crate::candidate::SearchCandidate;

pub(crate) const CHUNK_PARENT_THRESHOLD_BYTES: usize = 128 * 1024;
pub(crate) const PROXIMITY_BOOST_SCALE: f32 = 1000.0;

pub(crate) struct PhaseOneAdmissionPolicy;

impl PhaseOneAdmissionPolicy {
    pub(crate) const REGULAR_HEAD_LIMIT: usize = 64;
    pub(crate) const LARGE_HEAD_LIMIT: usize = 8;
    pub(crate) const TOTAL_HEAD_LIMIT: usize =
        Self::REGULAR_HEAD_LIMIT + Self::LARGE_HEAD_LIMIT;

    pub(crate) fn is_large_parent(parent_len: usize) -> bool {
        parent_len > CHUNK_PARENT_THRESHOLD_BYTES
    }

    pub(crate) fn blended_phase_one_score(raw_score: f32, timestamp: i64, parent_len: usize, now: i64) -> f64 {
        let base = (raw_score as f64).max(0.001);
        let proximity_tier = (base / PROXIMITY_BOOST_SCALE as f64).floor();
        let base_remainder = base - (proximity_tier * PROXIMITY_BOOST_SCALE as f64);
        let adjusted_remainder = if proximity_tier == 0.0 {
            (base_remainder - Self::phase_one_size_penalty(parent_len)).max(0.0)
        } else {
            base_remainder
        };

        let age_secs = (now - timestamp).max(0) as f64;
        let k: f64 = 20.0;
        let max_hours: f64 = 400.0;
        let age_hours = age_secs / 3600.0;
        let denom = (1.0 + k * max_hours).ln();
        let recency_score = 255.0 * (1.0 - (1.0 + k * age_hours).ln() / denom);
        let recency_score = recency_score.max(0.0);

        recency_score * 10.0 + proximity_tier * 100.0 + adjusted_remainder
    }

    pub(crate) fn should_stop_recall(
        candidates: &[SearchCandidate],
        last_raw_score: Option<f32>,
    ) -> bool {
        if candidates.len() < Self::TOTAL_HEAD_LIMIT {
            return false;
        }

        let Some(regular_threshold) = Self::regular_threshold(candidates) else {
            return false;
        };

        last_raw_score.is_some_and(|last_score| last_score < regular_threshold)
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
        indices.extend(
            regular
                .iter()
                .copied()
                .take(Self::REGULAR_HEAD_LIMIT),
        );

        if regular.len() >= Self::REGULAR_HEAD_LIMIT {
            let threshold = candidates[regular[Self::REGULAR_HEAD_LIMIT - 1]].tantivy_score;
            indices.extend(
                large
                    .iter()
                    .copied()
                    .filter(|&index| candidates[index].tantivy_score >= threshold)
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

    fn phase_one_size_penalty(parent_len: usize) -> f64 {
        match parent_len {
            0..=CHUNK_PARENT_THRESHOLD_BYTES => 0.0,
            ..=1_048_576 => 16.0,
            _ => 32.0,
        }
    }

    fn regular_threshold(candidates: &[SearchCandidate]) -> Option<f32> {
        candidates
            .iter()
            .filter(|candidate| !Self::is_large_parent(candidate.parent_len()))
            .nth(Self::REGULAR_HEAD_LIMIT.saturating_sub(1))
            .map(|candidate| candidate.tantivy_score)
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
