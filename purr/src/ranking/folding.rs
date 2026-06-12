//! Diacritic folding: the single text-equivalence used by indexing, phase-1
//! signals, tail admission, phase-2 matching, and highlighting. Folding is
//! lowercasing plus stripping canonical combining marks ('é' -> 'e', 'Ü' -> 'u'),
//! matching NSString's caseInsensitive + diacriticInsensitive semantics.
//!
//! Load-bearing invariant: folding is char-count preserving — exactly one
//! output char per input char — so char-indexed spans computed on folded text
//! are valid on the original text. Byte offsets are NOT preserved.
//!
//! Out of scope by design (would break the 1:1 invariant):
//! - multi-char case folds and ligatures: 'ß', 'œ', 'æ', 'ﬁ' stay as-is, so
//!   "strasse" does not find "straße"
//! - compatibility (NFKD) decompositions: '²', full-width forms stay as-is
//! - Hangul syllables: NFD yields Jamo letters, not combining marks, so they
//!   are left untouched; CJK has no decomposition and is unaffected

use unicode_normalization::char::{decompose_canonical, is_combining_mark};

/// Fold one char: lowercase + canonical-decomposition base char. ASCII takes a
/// table-free fast path; chars whose decomposition tail is not all combining
/// marks (e.g. Hangul) and chars without a single-char lowercase are returned
/// unchanged to preserve the 1:1 invariant.
pub(crate) fn fold_char(c: char) -> char {
    if c.is_ascii() {
        return c.to_ascii_lowercase();
    }

    let mut base = None;
    let mut tail_is_marks = true;
    decompose_canonical(c, |decomposed| {
        if base.is_none() {
            base = Some(decomposed);
        } else if !is_combining_mark(decomposed) {
            tail_is_marks = false;
        }
    });

    let candidate = match base {
        Some(base) if tail_is_marks => base,
        _ => c,
    };
    lowercase_single(candidate)
}

/// Lowercase only when it stays a single char ('İ' would expand to "i\u{307}"
/// via `to_lowercase`; its decomposition path above already yields 'i').
fn lowercase_single(c: char) -> char {
    let mut lowered = c.to_lowercase();
    match (lowered.next(), lowered.next()) {
        (Some(single), None) => single,
        _ => c,
    }
}

/// Fold a string char-by-char. Same allocation shape as `str::to_lowercase`,
/// which this replaces at every comparison site.
pub(crate) fn fold_str(s: &str) -> String {
    if s.is_ascii() {
        s.to_ascii_lowercase()
    } else {
        s.chars().map(fold_char).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::{fold_char, fold_str};

    #[test]
    fn fold_char_strips_canonical_marks() {
        assert_eq!(fold_char('é'), 'e');
        assert_eq!(fold_char('Ü'), 'u');
        assert_eq!(fold_char('ñ'), 'n');
        assert_eq!(fold_char('ç'), 'c');
        assert_eq!(fold_char('å'), 'a');
        assert_eq!(fold_char('ė'), 'e');
        // Vietnamese: recursive decomposition with two combining marks
        assert_eq!(fold_char('ế'), 'e');
        // Greek tonos
        assert_eq!(fold_char('ά'), 'α');
        // Cyrillic short i and yo
        assert_eq!(fold_char('й'), 'и');
        assert_eq!(fold_char('ё'), 'е');
    }

    #[test]
    fn fold_char_leaves_non_1to1_cases() {
        assert_eq!(fold_char('ß'), 'ß');
        assert_eq!(fold_char('ẞ'), 'ß');
        assert_eq!(fold_char('œ'), 'œ');
        assert_eq!(fold_char('æ'), 'æ');
        assert_eq!(fold_char('ﬁ'), 'ﬁ');
        // Hangul NFD is Jamo letters, not marks: must not fold
        assert_eq!(fold_char('한'), '한');
        assert_eq!(fold_char('北'), '北');
        assert_eq!(fold_char('a'), 'a');
        assert_eq!(fold_char('Z'), 'z');
    }

    #[test]
    fn fold_str_preserves_char_count() {
        let corpus =
            "Résumé ÜBER café Zürich naïve ế ά й ё ß straße œuf ﬁle 한국어 北京 plain ascii 123";
        assert_eq!(fold_str(corpus).chars().count(), corpus.chars().count());
        assert_eq!(fold_str("Résumé"), "resume");
        assert_eq!(fold_str("über"), "uber");
    }
}
