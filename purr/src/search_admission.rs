use crate::candidate::SearchCandidate;
use crate::ranking::{
    does_word_match, fold_str, prefix_match_for_query_word, PrefixMatch, WordMatchKind,
    LARGE_DOC_THRESHOLD_BYTES, NON_FINAL_PREFIX_MIN_QUERY_CHARS,
};
use crate::search::{is_word_token, tokenize_words};

pub(crate) const CHUNK_PARENT_THRESHOLD_BYTES: usize = 128 * 1024;
pub(crate) const PROXIMITY_BOOST_SCALE: f32 = 1000.0;
/// ConstScoreQuery signal added when any query word matches in content_words.
/// Chosen to be far above any realistic BM25 + proximity score so it can be
/// cleanly extracted without ambiguity.
pub(crate) const WORD_MATCH_SIGNAL: f32 = 100_000.0;
/// ConstScoreQuery signal added when a prefix/typo variant of a query word
/// matches in content_words. Sits in its own band between [`WORD_MATCH_SIGNAL`]
/// and [`PROXIMITY_BOOST_SCALE`]; ordering-only — admission never trusts the
/// index automaton, which is looser than `does_word_match`.
pub(crate) const WEAK_WORD_MATCH_SIGNAL: f32 = 10_000.0;
/// Cap on per-query weak-signal words: 9 x 10_000 stays below
/// [`WORD_MATCH_SIGNAL`] (100_000), so the weak band can never bleed into the
/// exact word-match band above it. Tail verification mirrors the cap so
/// per-candidate scan work stays bounded for pasted many-word queries.
pub(crate) const MAX_WEAK_SIGNAL_WORDS: usize = 9;

/// Structured Phase 1 score replacing the old magnitude-encoded f32.
///
/// Field order defines the lexicographic ranking policy via `derive(Ord)`:
/// 1. word_match_count — number of query words with exact word-level matches
/// 2. weak_word_match_count — query words with prefix/typo-variant evidence
/// 3. proximity_tier — count of matched constant-score proximity clauses
///    (slop-3 phrase, trailing-prefix phrase), at most 2; constant scoring
///    keeps the proximity band below [`WEAK_WORD_MATCH_SIGNAL`]
/// 4. evidence_density_score — weak huge-parent matches decay before recency
/// 5. recency_score — logarithmic recency decay (0-2550, scaled 10x from u8)
/// 6. bm25_remainder — BM25 score below the proximity band, quantized to u16
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct PhaseOneBlendedScore {
    pub word_match_count: u32,
    pub weak_word_match_count: u32,
    pub proximity_tier: u16,
    pub evidence_density_score: u16,
    pub recency_score: u16,
    pub bm25_remainder: u16,
}

impl PhaseOneBlendedScore {
    /// Decode a raw Tantivy f32 score that carries magnitude-encoded signals:
    ///
    /// - **Word match count**: each matched query word adds [`WORD_MATCH_SIGNAL`]
    ///   (100 000) via `ConstScoreQuery` on `content_words`.
    /// - **Weak word match count**: each query word with a prefix/typo-variant
    ///   match adds [`WEAK_WORD_MATCH_SIGNAL`] (10 000) via `ConstScoreQuery`.
    /// - **Proximity tier**: each matched proximity phrase clause adds
    ///   [`PROXIMITY_BOOST_SCALE`] (1 000) via `ConstScoreQuery`.
    /// - **BM25 remainder**: whatever is left after stripping the above bands,
    ///   optionally reduced by a size penalty for large parents.
    ///
    /// Recency is computed independently from the timestamp.
    pub(crate) fn decode(raw_score: f32, timestamp: i64, parent_len: usize, now: i64) -> Self {
        let base = (raw_score as f64).max(0.001);

        let word_match_count = (base / WORD_MATCH_SIGNAL as f64).floor() as u32;
        let base = base - (word_match_count as f64 * WORD_MATCH_SIGNAL as f64);

        let weak_word_match_count = (base / WEAK_WORD_MATCH_SIGNAL as f64).floor() as u32;
        let base = base - (weak_word_match_count as f64 * WEAK_WORD_MATCH_SIGNAL as f64);

        let proximity_tier = (base / PROXIMITY_BOOST_SCALE as f64).floor();
        let proximity_tier_score = proximity_tier as u16;
        let base_remainder = base - (proximity_tier * PROXIMITY_BOOST_SCALE as f64);
        let adjusted_remainder = if proximity_tier == 0.0 {
            (base_remainder - phase_one_size_penalty(parent_len)).max(0.0)
        } else {
            base_remainder
        };

        let evidence_density_score =
            compute_evidence_density_score(parent_len, word_match_count, proximity_tier_score);
        let recency_score = compute_recency(timestamp, now);

        Self {
            word_match_count,
            weak_word_match_count,
            proximity_tier: proximity_tier_score,
            evidence_density_score,
            recency_score: (recency_score * 10.0).round() as u16,
            bm25_remainder: (adjusted_remainder * 100.0)
                .round()
                .clamp(0.0, u16::MAX as f64) as u16,
        }
    }
}

const MAX_EVIDENCE_DENSITY_SCORE: u16 = 1000;

/// Compensate for the "lottery ticket" advantage of huge parents.
///
/// Chunking makes matching local, but a 2 MB parent still has many more chunks
/// that can accidentally match a common query than a compact item. Proximity is
/// strong local evidence, so it keeps full density. Otherwise, length decays the
/// score and exact word matches soften that decay.
fn compute_evidence_density_score(
    parent_len: usize,
    word_match_count: u32,
    proximity_tier: u16,
) -> u16 {
    if parent_len <= CHUNK_PARENT_THRESHOLD_BYTES || proximity_tier > 0 {
        return MAX_EVIDENCE_DENSITY_SCORE;
    }

    let parent_ratio = parent_len as f64 / CHUNK_PARENT_THRESHOLD_BYTES as f64;
    let doublings = parent_ratio.log2().max(0.0);
    if doublings == 0.0 {
        return MAX_EVIDENCE_DENSITY_SCORE;
    }

    let (penalty_per_doubling, floor) = match word_match_count {
        0 => (220.0, 120.0),
        1 => (170.0, 220.0),
        2 => (120.0, 380.0),
        _ => (80.0, 560.0),
    };

    (MAX_EVIDENCE_DENSITY_SCORE as f64 - doublings * penalty_per_doubling)
        .round()
        .clamp(floor, MAX_EVIDENCE_DENSITY_SCORE as f64) as u16
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
            weak_word_match_count: 0,
            proximity_tier: 0,
            evidence_density_score: MAX_EVIDENCE_DENSITY_SCORE,
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
    /// Cap on scan-verified tail candidates that get a lazy Phase 2 bucket
    /// scoring pass, so a fresh variant match ranks where it would in a small
    /// history while the added per-keystroke cost stays bounded.
    pub(crate) const TAIL_RESCUE_HEAD_LIMIT: usize = 16;

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

        // Only stop once the recall frontier has descended past the exact and
        // weak word-evidence bands into pure trigram noise; while the frontier
        // still carries word evidence, deeper batches can contain variant-class
        // candidates that scan-verified tail rescue admits. Work stays bounded
        // by RAW_RECALL_BATCHES.
        last_score.is_some_and(|s| {
            s < regular_threshold && s.word_match_count == 0 && s.weak_word_match_count == 0
        })
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
    pub(crate) fn from_indices(indices: Vec<usize>) -> Self {
        Self { indices }
    }

    pub(crate) fn indices(&self) -> &[usize] {
        &self.indices
    }

    pub(crate) fn into_indices(self) -> Vec<usize> {
        self.indices
    }
}

/// Hard cap on per-search tail-scan work, in scanned-byte-equivalent units.
/// Charges model the work actually done: pass 1 costs content bytes per word
/// scanned, pass 2 costs [`TAIL_SCAN_PASS_TWO_COST_MULTIPLIER`]x bytes per
/// word it still has to match, and every candidate pays a flat setup constant
/// so histories of thousands of tiny snippets are bounded by total work, not
/// bytes. On exhaustion, remaining candidates fall back to the exact-only
/// admission rule (deterministic: candidates are processed in a fixed order).
pub(crate) const TAIL_SCAN_BUDGET_UNITS: usize = 4 * 1024 * 1024;

const TAIL_SCAN_PASS_TWO_COST_MULTIPLIER: usize = 8;

/// Flat per-candidate charge covering tokenization/setup constants that do
/// not scale with content length.
const TAIL_SCAN_PER_CANDIDATE_COST_UNITS: usize = 512;

pub(crate) struct TailScanBudget {
    units_left: usize,
}

impl TailScanBudget {
    pub(crate) fn new(units: usize) -> Self {
        Self { units_left: units }
    }

    /// An oversized charge fails without draining the remainder, so later
    /// smaller candidates can still use the budget that is left.
    fn try_charge(&mut self, units: usize) -> bool {
        if units > self.units_left {
            return false;
        }
        self.units_left -= units;
        true
    }
}

/// Outcome of scan-verifying a tail candidate's word evidence.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TailEvidence {
    Verified,
    NoEvidence,
    BudgetExhausted,
}

/// Query-side state for scan-verified tail admission, built once per search
/// from the same eligible words that derive `min_word_matches`. Capped at
/// [`MAX_WEAK_SIGNAL_WORDS`] so pasted many-word queries cannot multiply
/// per-candidate scan work without bound.
pub(crate) struct TailVerifyQuery {
    words: Vec<TailVerifyWord>,
}

struct TailVerifyWord {
    word_folded: String,
    char_count: usize,
    prefix_match: PrefixMatch,
}

impl TailVerifyWord {
    /// Words at the contained-match floor may sit anywhere inside a token
    /// (prefix/subword/infix classes); shorter words only match whole tokens
    /// or enabled prefixes.
    fn allows_inner_hit(&self) -> bool {
        self.char_count >= NON_FINAL_PREFIX_MIN_QUERY_CHARS
    }

    fn allows_prefix_hit(&self) -> bool {
        matches!(
            self.prefix_match,
            PrefixMatch::Enabled { min_query_chars } if self.char_count >= min_query_chars
        )
    }
}

impl TailVerifyQuery {
    pub(crate) fn new(
        words: &[String],
        last_word_is_prefix: bool,
        signal_min_chars: usize,
    ) -> Self {
        let verify_words = words
            .iter()
            .enumerate()
            .filter_map(|(index, word)| {
                let char_count = word.chars().count();
                (char_count >= signal_min_chars).then(|| TailVerifyWord {
                    word_folded: fold_str(word),
                    char_count,
                    prefix_match: prefix_match_for_query_word(
                        words.len(),
                        index,
                        last_word_is_prefix,
                    ),
                })
            })
            .take(MAX_WEAK_SIGNAL_WORDS)
            .collect();
        Self {
            words: verify_words,
        }
    }

    /// Number of words verification scans for; admission thresholds must be
    /// derived from this capped set so they stay satisfiable.
    pub(crate) fn word_count(&self) -> usize {
        self.words.len()
    }
}

/// Verify that a tail candidate has word-level evidence for at least
/// `min_word_matches` query words, using the same match classes Phase 2 ranks.
///
/// Pass 1 is a fold-insensitive substring scan (covers the exact, prefix,
/// subword, and infix classes); contents above [`LARGE_DOC_THRESHOLD_BYTES`]
/// only honor token-start-anchored exact/prefix hits, mirroring Phase 2's
/// large-doc fast matching. Pass 2 tokenizes and runs full `does_word_match`
/// for the words pass 1 missed (fuzzy and subsequence classes), small
/// contents only.
///
/// Budget charges track the work actually performed: a flat per-candidate
/// constant, content bytes per pass-1 word scan (bailing mid-candidate once
/// exhausted), and 8x content bytes per word pass 2 still has to match.
pub(crate) fn verify_tail_word_evidence(
    content: &str,
    query: &TailVerifyQuery,
    min_word_matches: u32,
    budget: &mut TailScanBudget,
) -> TailEvidence {
    if min_word_matches == 0 {
        return TailEvidence::Verified;
    }
    if query.words.is_empty() {
        return TailEvidence::NoEvidence;
    }
    if !budget.try_charge(TAIL_SCAN_PER_CANDIDATE_COST_UNITS) {
        return TailEvidence::BudgetExhausted;
    }

    let token_start_required = content.len() > LARGE_DOC_THRESHOLD_BYTES;
    // Non-ASCII content must be folded even for ASCII needles so an accented
    // document word ("résumé") yields evidence for its folded query ("resume").
    let content_folded = (!content.is_ascii()).then(|| fold_str(content));

    let mut matched = vec![false; query.words.len()];
    let mut matched_count = 0u32;
    for (index, word) in query.words.iter().enumerate() {
        // Pass-1 work is one content scan per word.
        if !budget.try_charge(content.len()) {
            return TailEvidence::BudgetExhausted;
        }
        let hit = match content_folded.as_deref() {
            Some(content_folded) => {
                folded_substring_evidence(content_folded, word, token_start_required)
            }
            // ASCII content cannot contain a non-ASCII needle; the ASCII scan
            // correctly reports no pass-1 hit for those.
            None => ascii_substring_evidence(content.as_bytes(), word, token_start_required),
        };
        if hit {
            matched[index] = true;
            matched_count += 1;
            if matched_count >= min_word_matches {
                return TailEvidence::Verified;
            }
        }
    }

    // Large contents honor only exact + prefix classes (LargeFast parity);
    // pass 1 already covered those.
    if token_start_required {
        return TailEvidence::NoEvidence;
    }
    // Pass-2 work scales with the words still unmatched: every token is
    // checked against each of them.
    let unmatched_words = query.words.len() - matched_count as usize;
    if !budget.try_charge(
        content
            .len()
            .saturating_mul(TAIL_SCAN_PASS_TWO_COST_MULTIPLIER)
            .saturating_mul(unmatched_words),
    ) {
        return TailEvidence::BudgetExhausted;
    }

    for (_, _, doc_word) in tokenize_words(content) {
        if !is_word_token(&doc_word) {
            continue;
        }
        let dw_folded = fold_str(&doc_word);
        for (index, word) in query.words.iter().enumerate() {
            if matched[index] {
                continue;
            }
            if does_word_match(&word.word_folded, &dw_folded, &doc_word, word.prefix_match)
                != WordMatchKind::None
            {
                matched[index] = true;
                matched_count += 1;
                if matched_count >= min_word_matches {
                    return TailEvidence::Verified;
                }
            }
        }
    }

    TailEvidence::NoEvidence
}

/// A substring hit counts as word evidence only where a ranked match class
/// could place it: anywhere inside a token for words at the contained-match
/// floor, at a token start for enabled prefixes, or spanning a whole token
/// for exact matches.
fn hit_accepted(
    word: &TailVerifyWord,
    at_token_start: bool,
    at_token_end: bool,
    token_start_required: bool,
) -> bool {
    if token_start_required && !at_token_start {
        return false;
    }
    if word.allows_inner_hit() && !token_start_required {
        return true;
    }
    at_token_start && (at_token_end || word.allows_prefix_hit())
}

/// Allocation-free case-insensitive substring scan over ASCII-only content.
/// Bytes >= 0x80 are treated as alphanumeric for anchoring (multibyte chars
/// are usually letters), which can only under-admit.
fn ascii_substring_evidence(
    haystack: &[u8],
    word: &TailVerifyWord,
    token_start_required: bool,
) -> bool {
    let needle = word.word_folded.as_bytes();
    if needle.is_empty() || haystack.len() < needle.len() {
        return false;
    }
    for start in 0..=(haystack.len() - needle.len()) {
        if !haystack[start..start + needle.len()].eq_ignore_ascii_case(needle) {
            continue;
        }
        let end = start + needle.len();
        let at_token_start = start == 0 || !byte_is_alphanumeric(haystack[start - 1]);
        let at_token_end = end == haystack.len() || !byte_is_alphanumeric(haystack[end]);
        if hit_accepted(word, at_token_start, at_token_end, token_start_required) {
            return true;
        }
    }
    false
}

fn byte_is_alphanumeric(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte >= 0x80
}

fn folded_substring_evidence(
    content_folded: &str,
    word: &TailVerifyWord,
    token_start_required: bool,
) -> bool {
    for (start, _) in content_folded.match_indices(word.word_folded.as_str()) {
        let end = start + word.word_folded.len();
        let at_token_start = content_folded[..start]
            .chars()
            .next_back()
            .map_or(true, |c| !c.is_alphanumeric());
        let at_token_end = content_folded[end..]
            .chars()
            .next()
            .map_or(true, |c| !c.is_alphanumeric());
        if hit_accepted(word, at_token_start, at_token_end, token_start_required) {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_700_000_000;

    fn raw_score(word_matches: u32, proximity_tier: u16, bm25: f32) -> f32 {
        word_matches as f32 * WORD_MATCH_SIGNAL
            + proximity_tier as f32 * PROXIMITY_BOOST_SCALE
            + bm25
    }

    #[test]
    fn weak_large_parent_gets_lower_evidence_density_than_compact_item() {
        let compact = PhaseOneBlendedScore::decode(raw_score(1, 0, 8.0), NOW, 2_048, NOW);
        let large = PhaseOneBlendedScore::decode(raw_score(1, 0, 8.0), NOW, 2 * 1024 * 1024, NOW);

        assert_eq!(compact.evidence_density_score, MAX_EVIDENCE_DENSITY_SCORE);
        assert!(
            large.evidence_density_score < compact.evidence_density_score,
            "weak evidence from huge parents should decay before recency/BM25"
        );
    }

    #[test]
    fn proximity_match_keeps_full_evidence_density_for_large_parent() {
        let large = PhaseOneBlendedScore::decode(raw_score(1, 1, 8.0), NOW, 2 * 1024 * 1024, NOW);

        assert_eq!(large.evidence_density_score, MAX_EVIDENCE_DENSITY_SCORE);
    }

    #[test]
    fn exact_word_matches_soften_but_do_not_remove_large_parent_decay() {
        let one_word =
            PhaseOneBlendedScore::decode(raw_score(1, 0, 8.0), NOW, 2 * 1024 * 1024, NOW);
        let three_words =
            PhaseOneBlendedScore::decode(raw_score(3, 0, 8.0), NOW, 2 * 1024 * 1024, NOW);

        assert!(three_words.evidence_density_score > one_word.evidence_density_score);
        assert!(three_words.evidence_density_score < MAX_EVIDENCE_DENSITY_SCORE);
    }

    #[test]
    fn evidence_density_sorts_before_recency_for_weak_large_matches() {
        let old_compact =
            PhaseOneBlendedScore::decode(raw_score(1, 0, 1.0), NOW - 400 * 3600, 2_048, NOW);
        let fresh_large =
            PhaseOneBlendedScore::decode(raw_score(1, 0, 500.0), NOW, 2 * 1024 * 1024, NOW);

        assert!(
            old_compact > fresh_large,
            "compact weak evidence should beat newer huge-parent weak evidence"
        );
    }

    #[test]
    fn decode_extracts_weak_word_match_band() {
        let raw = 1.0 * WORD_MATCH_SIGNAL
            + 2.0 * WEAK_WORD_MATCH_SIGNAL
            + 1.0 * PROXIMITY_BOOST_SCALE
            + 8.0;
        let decoded = PhaseOneBlendedScore::decode(raw, NOW, 2_048, NOW);

        assert_eq!(decoded.word_match_count, 1);
        assert_eq!(decoded.weak_word_match_count, 2);
        assert_eq!(decoded.proximity_tier, 1);
        assert_eq!(decoded.bm25_remainder, 800);
    }

    #[test]
    fn blend_orders_weak_word_evidence_above_recency() {
        let old_with_weak_evidence = PhaseOneBlendedScore::decode(
            1.0 * WEAK_WORD_MATCH_SIGNAL + 1.0,
            NOW - 300 * 3600,
            2_048,
            NOW,
        );
        let fresh_without_evidence = PhaseOneBlendedScore::decode(500.0, NOW, 2_048, NOW);

        assert_eq!(old_with_weak_evidence.word_match_count, 0);
        assert_eq!(fresh_without_evidence.word_match_count, 0);
        assert!(
            old_with_weak_evidence > fresh_without_evidence,
            "weak word evidence should dominate recency and BM25 noise"
        );
    }

    #[test]
    fn tail_scan_budget_exhaustion_falls_back_to_exact_only() {
        let query = TailVerifyQuery::new(&["error".to_string()], true, 2);
        let mut budget = TailScanBudget::new(0);

        // Exhausted budget reports BudgetExhausted; the indexer then applies
        // the exact-count rule, which the candidate already failed.
        assert_eq!(
            verify_tail_word_evidence("404 errors spiking on prod", &query, 1, &mut budget),
            TailEvidence::BudgetExhausted
        );

        let mut roomy_budget = TailScanBudget::new(TAIL_SCAN_BUDGET_UNITS);
        assert_eq!(
            verify_tail_word_evidence("404 errors spiking on prod", &query, 1, &mut roomy_budget),
            TailEvidence::Verified
        );
    }

    #[test]
    fn claim3_oversized_charge_preserves_budget_for_later_small_candidates() {
        let query = TailVerifyQuery::new(&["error".to_string()], true, 2);

        // An oversized candidate fails its charge without draining the
        // remainder, so a later small candidate that fits still verifies.
        let mut budget = TailScanBudget::new(2 * TAIL_SCAN_PER_CANDIDATE_COST_UNITS + 100);
        let big = "x".repeat(2000);
        assert_eq!(
            verify_tail_word_evidence(&big, &query, 1, &mut budget),
            TailEvidence::BudgetExhausted
        );
        assert_eq!(
            verify_tail_word_evidence("404 errors on prod", &query, 1, &mut budget),
            TailEvidence::Verified,
            "remaining budget must survive an oversized charge"
        );
    }

    #[test]
    fn tail_scan_budget_charges_per_word_scanned() {
        // Pass 1 costs one content scan per query word, bailing mid-candidate
        // once exhausted; a single per-candidate byte charge would let a
        // many-word query scan unbounded.
        let words: Vec<String> = ["alpha", "bravo", "error"]
            .iter()
            .map(|word| word.to_string())
            .collect();
        let query = TailVerifyQuery::new(&words, true, 2);
        let content = format!("{}error", "x".repeat(95));

        // Room for the flat charge plus two word scans; the third word (the
        // one that would match) is never reached.
        let mut tight =
            TailScanBudget::new(TAIL_SCAN_PER_CANDIDATE_COST_UNITS + 2 * content.len() + 50);
        assert_eq!(
            verify_tail_word_evidence(&content, &query, 1, &mut tight),
            TailEvidence::BudgetExhausted
        );

        let mut exact = TailScanBudget::new(TAIL_SCAN_PER_CANDIDATE_COST_UNITS + 3 * content.len());
        assert_eq!(
            verify_tail_word_evidence(&content, &query, 1, &mut exact),
            TailEvidence::Verified
        );
    }

    #[test]
    fn tail_scan_pass_two_charge_scales_with_unmatched_words() {
        let words: Vec<String> = ["zebra", "yodel"]
            .iter()
            .map(|word| word.to_string())
            .collect();
        let query = TailVerifyQuery::new(&words, true, 2);
        let content = "abc def";
        let pass_one_cost = TAIL_SCAN_PER_CANDIDATE_COST_UNITS + 2 * content.len();
        let pass_two_cost = 2 * 8 * content.len();

        // Pass 2 checks every token against each unmatched word, so its
        // charge carries the unmatched-word multiplier.
        let mut tight = TailScanBudget::new(pass_one_cost + pass_two_cost - 1);
        assert_eq!(
            verify_tail_word_evidence(content, &query, 1, &mut tight),
            TailEvidence::BudgetExhausted
        );

        let mut exact = TailScanBudget::new(pass_one_cost + pass_two_cost);
        assert_eq!(
            verify_tail_word_evidence(content, &query, 1, &mut exact),
            TailEvidence::NoEvidence
        );
    }

    #[test]
    fn tail_verify_query_caps_scanned_words() {
        let words: Vec<String> = (0..12).map(|index| format!("word{index:02}")).collect();
        let query = TailVerifyQuery::new(&words, true, 2);

        assert_eq!(
            query.word_count(),
            MAX_WEAK_SIGNAL_WORDS,
            "pasted many-word queries must not multiply per-candidate scan work"
        );
    }
}
