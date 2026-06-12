use super::folding::fold_str;
use strsim::osa_distance;
use triple_accel::levenshtein::{levenshtein_simd_k_with_opts, RDAMERAU_COSTS};

/// Result of matching a query word against a document word.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum WordMatchKind {
    None,
    Exact,
    Prefix { span: TokenMatchSpan },
    SubwordPrefix { span: TokenMatchSpan },
    InfixSubstring { span: TokenMatchSpan },
    Fuzzy(u8),
    Subsequence(u8),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TokenMatchSpan {
    pub(crate) start: usize,
    pub(crate) len: usize,
}

impl TokenMatchSpan {
    fn at_start(len: usize) -> Self {
        Self { start: 0, len }
    }

    pub(crate) fn end(self) -> usize {
        self.start + self.len
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FuzzyEditKind {
    CommonTransposition,
    RepeatedCharEdit,
    InsertionOrDeletion,
    Substitution,
    MultiEdit,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PrefixMatch {
    Disabled,
    Enabled { min_query_chars: usize },
}

/// Minimum chars for a completed (non-final) query word to prefix-match a longer
/// document word. Matches the codebase's "meaningful fragment" floor: 3-char
/// trigram queries, 3-char contained substrings, and 3-char fuzzy minimums.
pub(crate) const NON_FINAL_PREFIX_MIN_QUERY_CHARS: usize = 3;

/// Prefix-match policy per query word: a completed (space-terminated) word may
/// still prefix a longer document word when the fragment is discriminating
/// (>= 3 chars); the in-progress last word keeps generous 1/2-char thresholds;
/// an explicitly finalized last word (query ends non-alphanumeric) stays
/// disabled per the Milli "explicitly completed" contract.
pub(crate) fn prefix_match_for_query_word(
    query_word_count: usize,
    query_word_index: usize,
    last_word_is_prefix: bool,
) -> PrefixMatch {
    let is_last = query_word_index + 1 == query_word_count;
    if !is_last {
        return PrefixMatch::Enabled {
            min_query_chars: NON_FINAL_PREFIX_MIN_QUERY_CHARS,
        };
    }
    if !last_word_is_prefix {
        return PrefixMatch::Disabled;
    }

    PrefixMatch::Enabled {
        min_query_chars: if query_word_count > 1 { 1 } else { 2 },
    }
}

/// Check if a query word matches a document word using the same criteria
/// as ranking: exact -> prefix -> subword-prefix -> infix substring -> fuzzy
/// -> subsequence. `qw_folded` and `dw_folded` must already be folded via
/// `fold_str` (lowercase + char-count-preserving diacritic strip); `dw_raw`
/// preserves original casing for camelCase/digit boundary detection.
pub(crate) fn does_word_match(
    qw_folded: &str,
    dw_folded: &str,
    dw_raw: &str,
    prefix_match: PrefixMatch,
) -> WordMatchKind {
    if dw_folded == qw_folded {
        return WordMatchKind::Exact;
    }
    if let Some(span) = prefix_match_span(qw_folded, dw_folded, prefix_match) {
        return WordMatchKind::Prefix { span };
    }
    if let Some(contained_match) = classify_contained_match(qw_folded, dw_folded, dw_raw) {
        return contained_match;
    }
    let max_typo = max_edit_distance(qw_folded.chars().count());
    if max_typo > 0 {
        if let Some(dist) = edit_distance_bounded(qw_folded, dw_folded, max_typo) {
            if dist > 0 && allows_fuzzy_match(qw_folded, dw_folded, dist) {
                return WordMatchKind::Fuzzy(dist);
            }
        }
    }
    if let Some(gaps) = subsequence_match(qw_folded, dw_folded) {
        return WordMatchKind::Subsequence(gaps);
    }
    WordMatchKind::None
}

/// Fast word matching for large documents (>5KB). Only exact and prefix matching,
/// no fuzzy edit distance or subsequence matching. This is much faster as it avoids
/// expensive DP table allocations for edit distance computation.
pub(crate) fn does_word_match_fast(
    qw_folded: &str,
    dw_folded: &str,
    prefix_match: PrefixMatch,
) -> WordMatchKind {
    match_fast_folded(qw_folded, dw_folded, prefix_match)
}

/// Fast matching against a raw token slice. ASCII-heavy content stays allocation-free;
/// non-ASCII tokens fall back to folding the token once for comparison.
pub(crate) fn does_word_match_fast_raw(
    qw_folded: &str,
    dw_raw: &str,
    prefix_match: PrefixMatch,
) -> WordMatchKind {
    if qw_folded.is_ascii() && dw_raw.is_ascii() {
        if dw_raw.eq_ignore_ascii_case(qw_folded) {
            return WordMatchKind::Exact;
        }
        if let Some(span) = ascii_prefix_match_span(qw_folded, dw_raw, prefix_match) {
            return WordMatchKind::Prefix { span };
        }
        return WordMatchKind::None;
    }

    match_fast_folded(qw_folded, &fold_str(dw_raw), prefix_match)
}

fn ascii_starts_with_ignore_case(haystack: &[u8], needle_lower: &[u8]) -> bool {
    haystack.len() >= needle_lower.len()
        && haystack[..needle_lower.len()].eq_ignore_ascii_case(needle_lower)
}

fn match_fast_folded(qw_folded: &str, dw_folded: &str, prefix_match: PrefixMatch) -> WordMatchKind {
    if dw_folded == qw_folded {
        return WordMatchKind::Exact;
    }
    if let Some(span) = prefix_match_span(qw_folded, dw_folded, prefix_match) {
        return WordMatchKind::Prefix { span };
    }
    WordMatchKind::None
}

fn prefix_match_span(
    qw_folded: &str,
    dw_folded: &str,
    prefix_match: PrefixMatch,
) -> Option<TokenMatchSpan> {
    match prefix_match {
        PrefixMatch::Disabled => None,
        PrefixMatch::Enabled { min_query_chars } => {
            let query_len = qw_folded.chars().count();
            (query_len >= min_query_chars && dw_folded.starts_with(qw_folded))
                .then(|| TokenMatchSpan::at_start(query_len))
        }
    }
}

fn ascii_prefix_match_span(
    qw_folded: &str,
    dw_raw: &str,
    prefix_match: PrefixMatch,
) -> Option<TokenMatchSpan> {
    match prefix_match {
        PrefixMatch::Disabled => None,
        PrefixMatch::Enabled { min_query_chars } => {
            let query_len = qw_folded.chars().count();
            (query_len >= min_query_chars
                && ascii_starts_with_ignore_case(dw_raw.as_bytes(), qw_folded.as_bytes()))
            .then(|| TokenMatchSpan::at_start(query_len))
        }
    }
}

fn classify_contained_match(
    qw_folded: &str,
    dw_folded: &str,
    dw_raw: &str,
) -> Option<WordMatchKind> {
    let query_chars: Vec<char> = qw_folded.chars().collect();
    let doc_folded_chars: Vec<char> = dw_folded.chars().collect();
    if query_chars.len() < 3 || query_chars.len() >= doc_folded_chars.len() {
        return None;
    }

    // fold_str is 1:1 per char so this never trips for folded input; kept as
    // defense against callers passing differently normalized text.
    let doc_raw_chars: Vec<char> = dw_raw.chars().collect();
    if doc_raw_chars.len() != doc_folded_chars.len() {
        return None;
    }

    // Scan starts at 1: word-start fragments belong to the higher-ranked Prefix
    // arm when prefix matching is enabled; when it is deliberately Disabled,
    // classifying them here would reopen that gate.
    for start in 1..=(doc_folded_chars.len() - query_chars.len()) {
        if doc_folded_chars[start..start + query_chars.len()] == query_chars[..] {
            let span = TokenMatchSpan {
                start,
                len: query_chars.len(),
            };
            return Some(if is_subword_boundary(&doc_raw_chars, start) {
                WordMatchKind::SubwordPrefix { span }
            } else {
                WordMatchKind::InfixSubstring { span }
            });
        }
    }

    None
}

fn is_subword_boundary(doc_raw_chars: &[char], start: usize) -> bool {
    if start == 0 || start >= doc_raw_chars.len() {
        return false;
    }

    let prev = doc_raw_chars[start - 1];
    let curr = doc_raw_chars[start];
    let next = doc_raw_chars.get(start + 1).copied();

    (prev.is_lowercase() && curr.is_uppercase())
        || (prev.is_alphabetic() && curr.is_numeric())
        || (prev.is_numeric() && curr.is_alphabetic())
        || (prev.is_uppercase() && curr.is_uppercase() && next.is_some_and(|ch| ch.is_lowercase()))
}

/// Check if all characters in `query` appear in order in `target`.
/// Returns the number of gaps (non-contiguous segments - 1) if matched, None otherwise.
pub(super) fn subsequence_match(query: &str, target: &str) -> Option<u8> {
    let q_chars: Vec<char> = query.chars().collect();
    let t_chars: Vec<char> = target.chars().collect();

    // Min 4 chars to avoid spurious matches (<=3 too short for meaningful subsequence)
    if q_chars.len() <= 3 {
        return None;
    }
    // Must be shorter than target (equal/longer is exact territory)
    if q_chars.len() >= t_chars.len() {
        return None;
    }
    // Query must cover at least 50% of target length
    if q_chars.len() * 2 < t_chars.len() {
        return None;
    }
    // First character must match (abbreviations preserve the initial letter)
    if q_chars[0] != t_chars[0] {
        return None;
    }

    let mut qi = 0;
    let mut gaps = 0u8;
    let mut prev_matched = false;

    for &tc in &t_chars {
        if qi < q_chars.len() && tc == q_chars[qi] {
            if !prev_matched && qi > 0 {
                gaps = gaps.saturating_add(1);
            }
            qi += 1;
            prev_matched = true;
        } else {
            prev_matched = false;
        }
    }

    if qi == q_chars.len() {
        Some(gaps)
    } else {
        None
    }
}

/// Maximum allowed edit distance based on word length (Milli's graduation).
/// 1-2 char words get no fuzzy tolerance. 3+ chars can enter the fuzzy path,
/// with additional short-token and wordlike-token gating below.
pub(crate) fn max_edit_distance(word_len: usize) -> u8 {
    if word_len < 3 {
        0
    } else if word_len <= 8 {
        1
    } else {
        2
    }
}

pub(crate) fn query_allows_fuzzy_recall(query_word: &str) -> bool {
    query_word.chars().count() >= 3 && is_wordlike_fuzzy_token(query_word)
}

fn token_allows_fuzzy_match(token: &str) -> bool {
    is_wordlike_fuzzy_token(token)
}

fn is_wordlike_fuzzy_token(token: &str) -> bool {
    token.chars().any(char::is_alphabetic) && token.chars().all(char::is_alphanumeric)
}

fn allows_short_fuzzy_match(query: &str, target: &str, dist: u8) -> bool {
    match classify_fuzzy_edit(query, target, dist) {
        FuzzyEditKind::CommonTransposition
        | FuzzyEditKind::RepeatedCharEdit
        | FuzzyEditKind::InsertionOrDeletion => true,
        FuzzyEditKind::Substitution | FuzzyEditKind::MultiEdit => false,
    }
}

fn allows_fuzzy_match(query: &str, target: &str, dist: u8) -> bool {
    if !query_allows_fuzzy_recall(query) || !token_allows_fuzzy_match(target) {
        return false;
    }

    if query.chars().count() == 3 {
        return allows_short_fuzzy_match(query, target, dist);
    }

    true
}

pub(crate) fn classify_fuzzy_edit(query: &str, target: &str, dist: u8) -> FuzzyEditKind {
    if is_adjacent_transposition(query, target) {
        return FuzzyEditKind::CommonTransposition;
    }

    if dist == 1 {
        if let Some(is_repeated_char) = classify_single_insert_delete(query, target) {
            return if is_repeated_char {
                FuzzyEditKind::RepeatedCharEdit
            } else {
                FuzzyEditKind::InsertionOrDeletion
            };
        }
        return FuzzyEditKind::Substitution;
    }

    FuzzyEditKind::MultiEdit
}

fn is_adjacent_transposition(a: &str, b: &str) -> bool {
    let a_chars: Vec<char> = a.chars().collect();
    let b_chars: Vec<char> = b.chars().collect();
    if a_chars.len() != b_chars.len() || a_chars.len() < 2 {
        return false;
    }

    let mut first_diff = None;
    for i in 0..a_chars.len() {
        if a_chars[i] != b_chars[i] {
            first_diff = Some(i);
            break;
        }
    }
    let Some(i) = first_diff else {
        return false;
    };
    if i + 1 >= a_chars.len() {
        return false;
    }

    if a_chars[i] != b_chars[i + 1] || a_chars[i + 1] != b_chars[i] {
        return false;
    }

    for j in (i + 2)..a_chars.len() {
        if a_chars[j] != b_chars[j] {
            return false;
        }
    }

    true
}

/// Returns whether the edit is a repeated-char insertion/deletion when the strings
/// differ by a single inserted or deleted character. `None` means it is not a
/// one-char insertion/deletion relationship.
fn classify_single_insert_delete(shorter: &str, longer: &str) -> Option<bool> {
    let shorter_chars: Vec<char> = shorter.chars().collect();
    let longer_chars: Vec<char> = longer.chars().collect();
    let (shorter_chars, longer_chars) = if shorter_chars.len() <= longer_chars.len() {
        (shorter_chars, longer_chars)
    } else {
        (longer_chars, shorter_chars)
    };

    if longer_chars.len() != shorter_chars.len() + 1 {
        return None;
    }

    let mut si = 0usize;
    let mut li = 0usize;
    let mut skipped_idx = None;

    while si < shorter_chars.len() && li < longer_chars.len() {
        if shorter_chars[si] == longer_chars[li] {
            si += 1;
            li += 1;
            continue;
        }

        if skipped_idx.is_some() {
            return None;
        }

        skipped_idx = Some(li);
        li += 1;
    }

    let skipped_idx = skipped_idx.unwrap_or(longer_chars.len() - 1);
    let skipped_char = longer_chars[skipped_idx];
    let repeated_prev = skipped_idx > 0 && longer_chars[skipped_idx - 1] == skipped_char;
    let repeated_next =
        skipped_idx + 1 < longer_chars.len() && longer_chars[skipped_idx + 1] == skipped_char;

    Some(repeated_prev || repeated_next)
}

/// Damerau-Levenshtein edit distance (optimal string alignment) with threshold pruning.
/// Counts insertions, deletions, substitutions, and adjacent transpositions each as 1 edit.
/// Returns `Some(distance)` if distance <= max_dist, `None` otherwise.
///
/// Applies the "first-character rule": ~98% of real typos preserve the first letter,
/// so a first-character mismatch incurs an extra +1 penalty. This prevents false
/// positives like "cat"->"bat" (distance 1 + penalty 1 = 2, exceeds max_dist=1).
/// Exception: transpositions of the first two characters (e.g., "hte"->"the") are
/// exempt since they're common fast-typing errors.
pub fn edit_distance_bounded(a: &str, b: &str, max_dist: u8) -> Option<u8> {
    if a.is_ascii() && b.is_ascii() {
        return edit_distance_bounded_ascii(a, b, max_dist);
    }

    edit_distance_bounded_unicode(a, b, max_dist)
}

fn edit_distance_bounded_ascii(a: &str, b: &str, max_dist: u8) -> Option<u8> {
    let a_bytes = a.as_bytes();
    let b_bytes = b.as_bytes();
    let max_d = max_dist as usize;

    if a_bytes.is_empty() || b_bytes.is_empty() {
        let dist = a_bytes.len().max(b_bytes.len());
        return (dist <= max_d).then_some(dist as u8);
    }

    let is_first_char_transposed = a_bytes.len() >= 2
        && b_bytes.len() >= 2
        && a_bytes[0] == b_bytes[1]
        && a_bytes[1] == b_bytes[0];
    let first_char_penalty = usize::from(a_bytes[0] != b_bytes[0] && !is_first_char_transposed);
    if a_bytes.len().abs_diff(b_bytes.len()) + first_char_penalty > max_d {
        return None;
    }

    let remaining_budget = max_d.saturating_sub(first_char_penalty);
    let (dist, _) = levenshtein_simd_k_with_opts(
        a_bytes,
        b_bytes,
        remaining_budget as u32,
        false,
        RDAMERAU_COSTS,
    )?;
    let total_dist = dist as usize + first_char_penalty;

    (total_dist <= max_d).then_some(total_dist as u8)
}

fn edit_distance_bounded_unicode(a: &str, b: &str, max_dist: u8) -> Option<u8> {
    let a_chars: Vec<char> = a.chars().collect();
    let b_chars: Vec<char> = b.chars().collect();
    let max_d = max_dist as usize;

    if a_chars.is_empty() || b_chars.is_empty() {
        let dist = a_chars.len().max(b_chars.len());
        return (dist <= max_d).then_some(dist as u8);
    }

    // Preserve the current "first-character rule" while delegating the edit-distance
    // algorithm itself to `strsim`.
    let is_first_char_transposed = a_chars.len() >= 2
        && b_chars.len() >= 2
        && a_chars[0] == b_chars[1]
        && a_chars[1] == b_chars[0];
    let first_char_penalty = usize::from(a_chars[0] != b_chars[0] && !is_first_char_transposed);
    if a_chars.len().abs_diff(b_chars.len()) + first_char_penalty > max_d {
        return None;
    }

    let dist = osa_distance(a, b) + first_char_penalty;
    (dist <= max_d).then_some(dist as u8)
}

#[cfg(test)]
mod tests {
    use super::fold_str;
    use super::{does_word_match, does_word_match_fast_raw, PrefixMatch, WordMatchKind};

    #[test]
    fn folded_word_matches_classify_as_exact_and_prefix() {
        assert_eq!(
            does_word_match(
                &fold_str("resume"),
                &fold_str("résumé"),
                "résumé",
                PrefixMatch::Disabled,
            ),
            WordMatchKind::Exact
        );
        assert_eq!(
            does_word_match(
                &fold_str("uber"),
                &fold_str("über"),
                "über",
                PrefixMatch::Disabled,
            ),
            WordMatchKind::Exact
        );

        let prefix = does_word_match(
            &fold_str("resu"),
            &fold_str("résumé"),
            "résumé",
            PrefixMatch::Enabled { min_query_chars: 1 },
        );
        match prefix {
            WordMatchKind::Prefix { span } => {
                assert_eq!(span.start, 0);
                assert_eq!(span.len, 4);
            }
            other => panic!("expected folded prefix match, got {other:?}"),
        }

        // Non-ASCII doc token takes the fold fallback in the fast path
        assert_eq!(
            does_word_match_fast_raw(&fold_str("uber"), "über", PrefixMatch::Disabled),
            WordMatchKind::Exact
        );
    }
}
