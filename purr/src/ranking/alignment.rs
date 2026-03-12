use super::*;
use std::collections::HashSet;

pub(super) fn trim_match_candidates(candidates: Vec<WordMatch>) -> Vec<WordMatch> {
    const MAX_CANDIDATES_PER_QUERY_WORD: usize = 8;
    if candidates.len() <= MAX_CANDIDATES_PER_QUERY_WORD {
        return candidates;
    }

    let mut by_quality = candidates.clone();
    by_quality.sort_by(candidate_quality_cmp);

    let mut by_pos = candidates;
    by_pos.sort_by_key(|c| c.doc_word_pos().unwrap_or(usize::MAX));

    let mut chosen = Vec::new();
    let mut seen_positions = HashSet::new();

    for cand in by_quality.iter().take(4) {
        if let Some(doc_word_pos) = cand.doc_word_pos() {
            if seen_positions.insert(doc_word_pos) {
                chosen.push(*cand);
            }
        }
    }
    for cand in by_pos.iter().take(2).chain(by_pos.iter().rev().take(2)) {
        if let Some(doc_word_pos) = cand.doc_word_pos() {
            if seen_positions.insert(doc_word_pos) {
                chosen.push(*cand);
            }
        }
    }
    for cand in by_quality {
        if chosen.len() >= MAX_CANDIDATES_PER_QUERY_WORD {
            break;
        }
        if let Some(doc_word_pos) = cand.doc_word_pos() {
            if seen_positions.insert(doc_word_pos) {
                chosen.push(cand);
            }
        }
    }

    chosen
}

#[derive(Debug, Clone, Copy)]
struct IndexedCandidate {
    position_mask: u64,
    word_match: WordMatch,
}

fn build_indexed_candidate_lists(
    candidate_lists: &[Vec<WordMatch>],
) -> Option<Vec<Vec<IndexedCandidate>>> {
    let mut unique_positions = Vec::new();
    for candidate in candidate_lists.iter().flatten() {
        let Some(doc_word_pos) = candidate.doc_word_pos() else {
            continue;
        };
        if !unique_positions.contains(&doc_word_pos) {
            unique_positions.push(doc_word_pos);
        }
    }

    if unique_positions.len() > u64::BITS as usize {
        return None;
    }

    Some(
        candidate_lists
            .iter()
            .map(|candidates| {
                candidates
                    .iter()
                    .filter_map(|candidate| {
                        let doc_word_pos = candidate.doc_word_pos()?;
                        let bit_idx = unique_positions
                            .iter()
                            .position(|pos| *pos == doc_word_pos)?;
                        Some(IndexedCandidate {
                            position_mask: 1u64 << bit_idx,
                            word_match: *candidate,
                        })
                    })
                    .collect()
            })
            .collect(),
    )
}

/// Choose the best non-overlapping assignment from query terms to document terms.
///
/// Each query word gets either its default unmatched state or one concrete
/// document-word candidate. A document word position may only be used once. We
/// then maximize the alignment score, which prefers stronger match kinds,
/// better overall query coverage, and more structured sequences.
pub(super) fn choose_best_alignment(
    candidate_lists: &[Vec<WordMatch>],
    defaults: &[WordMatch],
) -> Vec<WordMatch> {
    let total_query_weight: u16 = defaults.iter().map(|m| m.query_weight).sum();
    let mut current = defaults.to_vec();
    let mut best = defaults.to_vec();
    let mut best_score = score_alignment(&best, total_query_weight);

    if let Some(indexed_candidate_lists) = build_indexed_candidate_lists(candidate_lists) {
        choose_best_alignment_recursive_indexed(
            0,
            &indexed_candidate_lists,
            defaults,
            total_query_weight,
            0,
            &mut current,
            &mut best,
            &mut best_score,
        );
        return best;
    }

    let mut used_positions = HashSet::new();
    choose_best_alignment_recursive_fallback(
        0,
        candidate_lists,
        defaults,
        total_query_weight,
        &mut used_positions,
        &mut current,
        &mut best,
        &mut best_score,
    );

    best
}

fn choose_best_alignment_recursive_indexed(
    qi: usize,
    candidate_lists: &[Vec<IndexedCandidate>],
    defaults: &[WordMatch],
    total_query_weight: u16,
    used_positions_mask: u64,
    current: &mut [WordMatch],
    best: &mut Vec<WordMatch>,
    best_score: &mut AlignmentScore,
) {
    if qi == candidate_lists.len() {
        let score = score_alignment(current, total_query_weight);
        if score > *best_score {
            *best_score = score;
            *best = current.to_vec();
        }
        return;
    }

    current[qi] = defaults[qi];
    choose_best_alignment_recursive_indexed(
        qi + 1,
        candidate_lists,
        defaults,
        total_query_weight,
        used_positions_mask,
        current,
        best,
        best_score,
    );

    for candidate in &candidate_lists[qi] {
        if used_positions_mask & candidate.position_mask != 0 {
            continue;
        }
        current[qi] = candidate.word_match;
        choose_best_alignment_recursive_indexed(
            qi + 1,
            candidate_lists,
            defaults,
            total_query_weight,
            used_positions_mask | candidate.position_mask,
            current,
            best,
            best_score,
        );
    }
}

fn choose_best_alignment_recursive_fallback(
    qi: usize,
    candidate_lists: &[Vec<WordMatch>],
    defaults: &[WordMatch],
    total_query_weight: u16,
    used_positions: &mut HashSet<usize>,
    current: &mut [WordMatch],
    best: &mut Vec<WordMatch>,
    best_score: &mut AlignmentScore,
) {
    if qi == candidate_lists.len() {
        let score = score_alignment(current, total_query_weight);
        if score > *best_score {
            *best_score = score;
            *best = current.to_vec();
        }
        return;
    }

    current[qi] = defaults[qi];
    choose_best_alignment_recursive_fallback(
        qi + 1,
        candidate_lists,
        defaults,
        total_query_weight,
        used_positions,
        current,
        best,
        best_score,
    );

    for candidate in &candidate_lists[qi] {
        let Some(doc_word_pos) = candidate.doc_word_pos() else {
            continue;
        };
        if !used_positions.insert(doc_word_pos) {
            continue;
        }
        current[qi] = *candidate;
        choose_best_alignment_recursive_fallback(
            qi + 1,
            candidate_lists,
            defaults,
            total_query_weight,
            used_positions,
            current,
            best,
            best_score,
        );
        used_positions.remove(&doc_word_pos);
    }
}

fn candidate_quality_cmp(a: &WordMatch, b: &WordMatch) -> std::cmp::Ordering {
    candidate_quality_key(b).cmp(&candidate_quality_key(a))
}

fn candidate_quality_key(m: &WordMatch) -> (u8, u8, u16, u8, std::cmp::Reverse<usize>) {
    let kind_rank = match m.state {
        WordMatchState::Exact { .. } => 6,
        WordMatchState::Prefix { .. } => 5,
        WordMatchState::SubwordPrefix { .. } => 4,
        WordMatchState::InfixSubstring { .. } => 3,
        WordMatchState::Fuzzy { .. } => 2,
        WordMatchState::Subsequence { .. } => 1,
        WordMatchState::Unmatched => 0,
    };
    (
        kind_rank,
        m.match_class_score(),
        m.matched_weight(),
        255u8.saturating_sub(m.edit_distance()),
        std::cmp::Reverse(m.doc_word_pos().unwrap_or(usize::MAX)),
    )
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct AlignmentScore {
    quality_tier: QualityTier,
    quality_detail: QualityDetail,
    matched_query_mask: u64,
}

fn score_alignment(word_matches: &[WordMatch], total_query_weight: u16) -> AlignmentScore {
    let signals = compute_alignment_quality_signals(word_matches, total_query_weight);

    AlignmentScore {
        quality_tier: signals.quality_tier(),
        quality_detail: signals.quality_detail(),
        matched_query_mask: alignment_matched_query_mask(word_matches),
    }
}

fn alignment_matched_query_mask(word_matches: &[WordMatch]) -> u64 {
    word_matches.iter().enumerate().fold(0u64, |mask, (i, wm)| {
        if !matches!(wm.state, WordMatchState::Unmatched) {
            mask | (1u64 << (63usize.saturating_sub(i)))
        } else {
            mask
        }
    })
}

pub(super) fn alignment_exactness_signals(word_matches: &[WordMatch]) -> ExactnessSignals {
    let matched_count = word_matches
        .iter()
        .filter(|m| !matches!(m.state, WordMatchState::Unmatched))
        .count();
    if matched_count == 0 {
        return ExactnessSignals::default();
    }
    if matched_count < 2 {
        return alignment_zero_cost_signals(word_matches);
    }

    let all_matched = word_matches
        .iter()
        .all(|m| !matches!(m.state, WordMatchState::Unmatched));
    if all_matched {
        let in_sequence =
            word_matches
                .windows(2)
                .all(|w| match (w[0].doc_word_pos(), w[1].doc_word_pos()) {
                    (Some(left), Some(right)) => right > left,
                    _ => false,
                });
        if in_sequence {
            let contiguous =
                word_matches
                    .windows(2)
                    .all(|w| match (w[0].doc_word_pos(), w[1].doc_word_pos()) {
                        (Some(left), Some(right)) => right == left + 1,
                        _ => false,
                    });
            if contiguous {
                return ExactnessSignals {
                    query_substring: true,
                    ..alignment_zero_cost_signals(word_matches)
                };
            }
            return ExactnessSignals {
                all_zero_cost: word_matches.iter().all(|m| m.edit_distance() == 0),
                any_zero_cost: word_matches.iter().any(|m| m.edit_distance() == 0),
                all_exact: word_matches
                    .iter()
                    .all(|m| matches!(m.state, WordMatchState::Exact { .. })),
                ..ExactnessSignals::default()
            };
        }
    }

    alignment_zero_cost_signals(word_matches)
}

fn alignment_zero_cost_signals(word_matches: &[WordMatch]) -> ExactnessSignals {
    ExactnessSignals {
        all_exact: word_matches
            .iter()
            .filter(|m| !matches!(m.state, WordMatchState::Unmatched))
            .all(|m| matches!(m.state, WordMatchState::Exact { .. })),
        all_zero_cost: word_matches
            .iter()
            .filter(|m| !matches!(m.state, WordMatchState::Unmatched))
            .all(|m| m.edit_distance() == 0),
        any_zero_cost: word_matches
            .iter()
            .filter(|m| !matches!(m.state, WordMatchState::Unmatched))
            .any(|m| m.edit_distance() == 0),
        ..ExactnessSignals::default()
    }
}
