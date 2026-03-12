/// Result of matching a query word against a document word.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum WordMatchKind {
    None,
    Exact,
    Prefix,
    SubwordPrefix,
    InfixSubstring,
    Fuzzy(u8),
    Subsequence(u8),
}

/// Check if a query word matches a document word using the same criteria
/// as ranking: exact -> prefix -> subword-prefix -> infix substring -> fuzzy
/// -> subsequence. `qw_lower` and `dw_lower` must already be lowercased; `dw_raw`
/// preserves original casing for camelCase/digit boundary detection.
pub(crate) fn does_word_match(
    qw_lower: &str,
    dw_lower: &str,
    dw_raw: &str,
    allow_prefix: bool,
) -> WordMatchKind {
    if dw_lower == qw_lower {
        return WordMatchKind::Exact;
    }
    if allow_prefix && qw_lower.len() >= 2 && dw_lower.starts_with(qw_lower) {
        return WordMatchKind::Prefix;
    }
    if let Some(contained_match) = classify_contained_match(qw_lower, dw_lower, dw_raw) {
        return contained_match;
    }
    let max_typo = max_edit_distance(qw_lower.chars().count());
    if max_typo > 0 {
        if let Some(dist) = edit_distance_bounded(qw_lower, dw_lower, max_typo) {
            if dist > 0 {
                return WordMatchKind::Fuzzy(dist);
            }
        }
    }
    if let Some(gaps) = subsequence_match(qw_lower, dw_lower) {
        return WordMatchKind::Subsequence(gaps);
    }
    WordMatchKind::None
}

/// Fast word matching for large documents (>5KB). Only exact and prefix matching,
/// no fuzzy edit distance or subsequence matching. This is much faster as it avoids
/// expensive DP table allocations for edit distance computation.
pub(crate) fn does_word_match_fast(
    qw_lower: &str,
    dw_lower: &str,
    allow_prefix: bool,
) -> WordMatchKind {
    if dw_lower == qw_lower {
        return WordMatchKind::Exact;
    }
    if allow_prefix && qw_lower.len() >= 2 && dw_lower.starts_with(qw_lower) {
        return WordMatchKind::Prefix;
    }
    WordMatchKind::None
}

fn classify_contained_match(qw_lower: &str, dw_lower: &str, dw_raw: &str) -> Option<WordMatchKind> {
    let query_chars: Vec<char> = qw_lower.chars().collect();
    let doc_lower_chars: Vec<char> = dw_lower.chars().collect();
    if query_chars.len() < 4 || query_chars.len() >= doc_lower_chars.len() {
        return None;
    }

    let doc_raw_chars: Vec<char> = dw_raw.chars().collect();
    if doc_raw_chars.len() != doc_lower_chars.len() {
        return None;
    }

    for start in 1..=(doc_lower_chars.len() - query_chars.len()) {
        if doc_lower_chars[start..start + query_chars.len()] == query_chars[..] {
            return Some(if is_subword_boundary(&doc_raw_chars, start) {
                WordMatchKind::SubwordPrefix
            } else {
                WordMatchKind::InfixSubstring
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
/// 1-2 char words get no fuzzy tolerance. 3+ chars allow 1 edit (catches transpositions).
pub(crate) fn max_edit_distance(word_len: usize) -> u8 {
    if word_len < 3 {
        0
    } else if word_len <= 8 {
        1
    } else {
        2
    }
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
    let a_chars: Vec<char> = a.chars().collect();
    let b_chars: Vec<char> = b.chars().collect();
    let m = a_chars.len();
    let n = b_chars.len();
    let max_d = max_dist as usize;

    if m == 0 || n == 0 {
        let dist = m.max(n);
        return if dist <= max_d {
            Some(dist as u8)
        } else {
            None
        };
    }

    // First-character penalty: mismatch on position 0 costs +1 edit.
    // Exception: first-two-char transposition ("hte"->"the") is a common fast-typing error.
    let is_first_char_transposed =
        m >= 2 && n >= 2 && a_chars[0] == b_chars[1] && a_chars[1] == b_chars[0];
    let first_char_penalty = if a_chars[0] != b_chars[0] && !is_first_char_transposed {
        1
    } else {
        0
    };
    if m.abs_diff(n) + first_char_penalty > max_d {
        return None;
    }

    let inf = max_d + 1;
    let mut prev2 = vec![inf; n + 1];
    let mut prev = vec![0usize; n + 1];
    let mut curr = vec![0usize; n + 1];

    for (j, cell) in prev.iter_mut().enumerate() {
        *cell = j;
    }

    for i in 1..=m {
        curr[0] = i;
        let mut row_min = curr[0];

        let start = i.saturating_sub(max_d);
        let end = (i + max_d).min(n);
        for j in 1..start {
            curr[j] = inf;
        }

        for j in start.max(1)..=end {
            let substitution_cost = usize::from(a_chars[i - 1] != b_chars[j - 1]);
            let mut best = (prev[j] + 1)
                .min(curr[j - 1] + 1)
                .min(prev[j - 1] + substitution_cost);

            if i > 1
                && j > 1
                && a_chars[i - 1] == b_chars[j - 2]
                && a_chars[i - 2] == b_chars[j - 1]
            {
                best = best.min(prev2[j - 2] + 1);
            }

            curr[j] = best;
            row_min = row_min.min(best);
        }

        for j in (end + 1)..=n {
            curr[j] = inf;
        }

        if row_min > max_d {
            return None;
        }

        std::mem::swap(&mut prev2, &mut prev);
        std::mem::swap(&mut prev, &mut curr);
    }

    let dist = prev[n] + first_char_penalty;
    if dist <= max_d {
        Some(dist as u8)
    } else {
        None
    }
}
