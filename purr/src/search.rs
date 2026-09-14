//! Search Engine (Tantivy with bucket ranking + word-level highlighting)
//!
//! Tantivy handles retrieval via trigram indexing with per-word PhraseQuery boosts.
//! Phase 2 bucket re-ranking (in indexer.rs) provides Milli-style lexicographic
//! ranking. Highlighting uses `does_word_match` from the ranking module to ensure
//! what's highlighted matches what's ranked (exact, prefix, substring, fuzzy edit-distance).
//! Short queries (< 3 chars) use a streaming fallback.

use crate::indexer::Indexer;
use crate::interface::ClipKittyError;
use crate::interface::{
    HighlightKind, ListPresentationProfile, MatchedExcerpt, PreviewDecoration, Utf16HighlightRange,
};
use crate::ranking::{
    does_word_match, does_word_match_fast, does_word_match_fast_raw, fold_str,
    prefix_match_for_query_word, WordMatchKind, LARGE_DOC_THRESHOLD_BYTES,
};
use tokio_util::sync::CancellationToken;

/// Maximum results to return from search.
pub(crate) const MAX_RESULTS: usize = 2000;

pub(crate) const MIN_TRIGRAM_QUERY_LEN: usize = 3;

/// Byte cap on the document prefix that highlighting tokenizes and scans.
///
/// Chosen as 8x `LARGE_DOC_THRESHOLD_BYTES` (256KB): comfortably above the
/// 16KB recall chunk a large item matches through and above any clip a user
/// reads in a preview pane, but small enough that a multi-megabyte paste costs
/// bounded work per keystroke instead of scaling with its full length.
pub(crate) const HIGHLIGHT_SCAN_LIMIT_BYTES: usize = 8 * LARGE_DOC_THRESHOLD_BYTES;

/// Context chars to include before/after match in snippet
pub(crate) const SNIPPET_CONTEXT_CHARS: usize = 200;

/// Maximum hard line breaks kept before the selected match in Card excerpts.
/// One leading break means the match starts on excerpt hard-line 2 at worst,
/// which stays visible even under the lineLimit(2) link/image cards.
const CARD_MAX_LEADING_LINE_BREAKS: usize = 1;

/// Leading char budget for Card excerpts. Together with the 1-char leading
/// ellipsis this is at most one wrapped line at the card font (15pt; the
/// narrowest layout is the 2-line link/image HStack with leading icon,
/// ~38 chars/line), so wrapping cannot push the match start past visible
/// line 2 either.
const CARD_LEADING_CONTEXT_CHARS: usize = 36;

// ─────────────────────────────────────────────────────────────────────────────
// Excerpt policy — profile-driven formatting
// ─────────────────────────────────────────────────────────────────────────────

/// How whitespace is treated during snippet normalization.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum WhitespaceMode {
    /// Collapse all whitespace (newlines, tabs, runs of spaces) into a single space.
    CollapseAll,
    /// Preserve single line breaks; collapse runs of 3+ newlines into 2; collapse
    /// tabs and horizontal whitespace runs into a single space.
    PreserveLineBreaks,
}

/// Controls how excerpts are formatted for a given presentation profile.
#[derive(Debug, Clone, Copy)]
pub(crate) struct ExcerptPolicy {
    pub(crate) whitespace_mode: WhitespaceMode,
    pub(crate) max_chars: usize,
    /// Window used to choose the best highlight cluster.
    pub(crate) context_chars: usize,
    /// Maximum normalized source characters to keep before the selected match.
    ///
    /// Multiline card rows are line-clamped by SwiftUI, so the match must stay
    /// near the top of the excerpt rather than centered in a large balanced
    /// character window. Trailing context is never expanded to compensate for
    /// a short lead: for matches near the end of content the excerpt is
    /// deliberately sparse, because extra leading content pushes the match
    /// back toward the clipped region.
    pub(crate) leading_context_chars: usize,
    /// Maximum hard line breaks kept before the selected match; None = unbounded.
    pub(crate) max_leading_line_breaks: Option<usize>,
}

impl ExcerptPolicy {
    pub(crate) fn for_profile(profile: ListPresentationProfile) -> Self {
        match profile {
            ListPresentationProfile::CompactRow => Self {
                whitespace_mode: WhitespaceMode::CollapseAll,
                max_chars: SNIPPET_CONTEXT_CHARS * 2, // 400
                context_chars: SNIPPET_CONTEXT_CHARS, // 200
                leading_context_chars: SNIPPET_CONTEXT_CHARS,
                // CollapseAll removes all newlines; a line cap is meaningless.
                max_leading_line_breaks: None,
            },
            ListPresentationProfile::Card => Self {
                whitespace_mode: WhitespaceMode::PreserveLineBreaks,
                max_chars: SNIPPET_CONTEXT_CHARS * 4,     // 800
                context_chars: SNIPPET_CONTEXT_CHARS * 2, // 400
                leading_context_chars: CARD_LEADING_CONTEXT_CHARS,
                max_leading_line_breaks: Some(CARD_MAX_LEADING_LINE_BREAKS),
            },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum SearchQuery {
    Plain {
        text: String,
    },
    PreferPrefix {
        raw_text: String,
        stripped_text: String,
    },
}

impl SearchQuery {
    pub(crate) fn parse(query: &str) -> Self {
        let trimmed = query.trim();
        if let Some(rest) = trimmed.strip_prefix('^') {
            let stripped = rest.trim_start();
            if !stripped.is_empty() {
                return Self::PreferPrefix {
                    raw_text: trimmed.to_string(),
                    stripped_text: stripped.to_string(),
                };
            }
        }

        Self::Plain {
            text: trimmed.to_string(),
        }
    }

    pub(crate) fn raw_text(&self) -> &str {
        match self {
            Self::Plain { text } => text,
            Self::PreferPrefix { raw_text, .. } => raw_text,
        }
    }

    pub(crate) fn recall_text(&self) -> &str {
        match self {
            Self::Plain { text } => text,
            Self::PreferPrefix { stripped_text, .. } => stripped_text,
        }
    }
}

#[derive(Debug, Clone)]
pub(crate) struct FuzzyMatch {
    pub(crate) highlight_ranges: Vec<HighlightRange>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct HighlightRange {
    pub(crate) start: u64,
    pub(crate) end: u64,
    pub(crate) kind: HighlightKind,
}

#[derive(Debug, Clone)]
pub(crate) struct HighlightAnalysis {
    pub(crate) highlights: Vec<HighlightRange>,
    pub(crate) initial_scroll_highlight_index: Option<u64>,
}

#[derive(Debug, Clone, Copy)]
enum PreviewHighlightLimit {
    FocusedWindow {
        max_highlights: usize,
        context_chars: u64,
    },
}

const PREVIEW_MAX_HIGHLIGHTS: usize = 64;
const PREVIEW_HIGHLIGHT_CONTEXT_CHARS: u64 = 2048;

fn utf16_offset_table(text: &str) -> Vec<u64> {
    let mut offsets = Vec::with_capacity(text.chars().count() + 1);
    let mut utf16_pos = 0u64;
    for ch in text.chars() {
        offsets.push(utf16_pos);
        utf16_pos += ch.len_utf16() as u64;
    }
    offsets.push(utf16_pos);
    offsets
}

fn scalar_highlights_to_utf16(
    text: &str,
    highlights: &[HighlightRange],
) -> Vec<Utf16HighlightRange> {
    let offsets = utf16_offset_table(text);
    highlights
        .iter()
        .filter_map(|highlight| {
            let start = usize::try_from(highlight.start).ok()?;
            let end = usize::try_from(highlight.end).ok()?;
            let utf16_start = *offsets.get(start)?;
            let utf16_end = *offsets.get(end)?;
            Some(Utf16HighlightRange {
                utf16_start,
                utf16_end,
                kind: highlight.kind,
            })
        })
        .collect()
}

fn limit_preview_highlights(
    analysis: &HighlightAnalysis,
    limit: PreviewHighlightLimit,
) -> (Vec<HighlightRange>, Option<u64>) {
    match limit {
        PreviewHighlightLimit::FocusedWindow {
            max_highlights,
            context_chars,
        } => {
            if analysis.highlights.is_empty() || max_highlights == 0 {
                return (Vec::new(), None);
            }

            if analysis.highlights.len() <= max_highlights {
                return (
                    analysis.highlights.clone(),
                    analysis.initial_scroll_highlight_index,
                );
            }

            let anchor_index = analysis
                .initial_scroll_highlight_index
                .and_then(|index| usize::try_from(index).ok())
                .filter(|index| *index < analysis.highlights.len())
                .unwrap_or(0);
            let anchor = &analysis.highlights[anchor_index];
            let window_start = anchor.start.saturating_sub(context_chars);
            let window_end = anchor.end.saturating_add(context_chars);

            let visible_indices: Vec<usize> = analysis
                .highlights
                .iter()
                .enumerate()
                .filter_map(|(index, highlight)| {
                    (highlight.end >= window_start && highlight.start <= window_end)
                        .then_some(index)
                })
                .collect();

            let (mut slice_start, mut slice_end) = if let (Some(first), Some(last)) =
                (visible_indices.first(), visible_indices.last())
            {
                (*first, last + 1)
            } else {
                (anchor_index, anchor_index + 1)
            };

            if slice_end - slice_start > max_highlights {
                let preferred_start = anchor_index.saturating_sub(max_highlights / 2);
                let max_start = slice_end.saturating_sub(max_highlights);
                slice_start = preferred_start.clamp(slice_start, max_start);
                slice_end = slice_start + max_highlights;
            }

            let limited = analysis.highlights[slice_start..slice_end].to_vec();
            let limited_anchor = anchor_index
                .checked_sub(slice_start)
                .map(|index| index as u64)
                .filter(|index| (*index as usize) < limited.len());

            (limited, limited_anchor)
        }
    }
}

/// Search using Tantivy with bucket re-ranking for trigram queries (>= 3 chars).
/// Phase 1 (trigram recall) and Phase 2 (bucket re-ranking) happen inside indexer.search().
/// Returns item-level search candidates with their best match context.
pub(crate) fn search_trigram_lazy(
    indexer: &Indexer,
    query: &SearchQuery,
    recall_filter: &crate::indexer::RecallFilter,
    token: &CancellationToken,
) -> Result<Vec<crate::candidate::SearchCandidate>, ClipKittyError> {
    if query.raw_text().is_empty() {
        return Ok(Vec::new());
    }

    // Bucket-ranked candidates from two-phase search
    #[cfg(feature = "perf-log")]
    let t0 = std::time::Instant::now();
    // `IndexerError::Cancelled` converts to `ClipKittyError::Cancelled`, so no
    // token re-check is needed to tell cancellation from a real index failure.
    let candidates = indexer.search_parsed_filtered(query, MAX_RESULTS, recall_filter, token)?;
    #[cfg(feature = "perf-log")]
    eprintln!(
        "[perf] indexer_total={:.1}ms candidates={}",
        (std::time::Instant::now() - t0).as_secs_f64() * 1000.0,
        candidates.len()
    );

    if token.is_cancelled() {
        return Err(ClipKittyError::Cancelled);
    }

    Ok(candidates)
}

/// Map a `WordMatchKind` from ranking to a `HighlightKind` for the UI.
fn word_match_to_highlight_kind(wmk: WordMatchKind) -> HighlightKind {
    match wmk {
        WordMatchKind::Exact => HighlightKind::Exact,
        WordMatchKind::Prefix { .. } => HighlightKind::Prefix,
        WordMatchKind::SubwordPrefix { .. } => HighlightKind::SubwordPrefix,
        WordMatchKind::InfixSubstring { .. } => HighlightKind::Substring,
        WordMatchKind::Fuzzy(_) => HighlightKind::Fuzzy,
        WordMatchKind::Subsequence(_) => HighlightKind::Subsequence,
        WordMatchKind::None => HighlightKind::Exact, // unreachable in practice
    }
}

fn append_word_highlight(
    highlights: &mut Vec<(DocToken, HighlightKind)>,
    content: &str,
    token: DocToken,
    word_match_kind: WordMatchKind,
) {
    let highlighted = match word_match_kind {
        WordMatchKind::Prefix { span }
        | WordMatchKind::SubwordPrefix { span }
        | WordMatchKind::InfixSubstring { span } => token.subspan(content, span.start, span.end()),
        WordMatchKind::Exact
        | WordMatchKind::Fuzzy(_)
        | WordMatchKind::Subsequence(_)
        | WordMatchKind::None => token,
    };

    highlights.push((highlighted, word_match_to_highlight_kind(word_match_kind)));

    if matches!(word_match_kind, WordMatchKind::Prefix { .. }) {
        if let Some(tail) = token.tail_after(&highlighted) {
            highlights.push((tail, HighlightKind::PrefixTail));
        }
    }
}

fn should_bridge_highlights(
    previous_kind: HighlightKind,
    next_kind: HighlightKind,
    gap: &str,
) -> bool {
    if matches!(previous_kind, HighlightKind::PrefixTail)
        || matches!(next_kind, HighlightKind::PrefixTail)
    {
        return false;
    }

    gap.is_empty()
        || gap
            .chars()
            .all(|c| !c.is_alphanumeric() && !c.is_whitespace())
}

/// A document token located by both char and byte offsets.
///
/// Char offsets are what `HighlightRange` speaks; byte offsets let callers
/// slice the token text straight out of the original `&str`, so tokenizing a
/// document costs no `Vec<char>` and no per-token `String`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct DocToken {
    pub char_start: usize,
    pub char_end: usize,
    pub byte_start: usize,
    pub byte_end: usize,
}

impl DocToken {
    /// The token's text, borrowed from the content it was tokenized from.
    pub(crate) fn text<'a>(&self, content: &'a str) -> &'a str {
        &content[self.byte_start..self.byte_end]
    }

    fn char_len(&self) -> usize {
        self.char_end.saturating_sub(self.char_start)
    }

    /// Narrow this token to the relative char range `[start, end)`, keeping the
    /// char and byte offsets in sync.
    ///
    /// Match kinds report spans in chars relative to the token, so the byte
    /// offsets have to be recomputed by walking the token's own text — short by
    /// construction, unlike the document.
    fn subspan(&self, content: &str, start: usize, end: usize) -> DocToken {
        let token_len = self.char_len();
        let relative_start = start.min(token_len);
        let relative_end = end.min(token_len).max(relative_start);
        if relative_start == 0 && relative_end == token_len {
            return *self;
        }

        let text = self.text(content);
        let byte_of = |char_offset: usize| -> usize {
            if char_offset == 0 {
                self.byte_start
            } else if char_offset >= token_len {
                self.byte_end
            } else {
                self.byte_start
                    + text
                        .char_indices()
                        .nth(char_offset)
                        .map(|(byte_index, _)| byte_index)
                        .unwrap_or(text.len())
            }
        };

        DocToken {
            char_start: self.char_start + relative_start,
            char_end: self.char_start + relative_end,
            byte_start: byte_of(relative_start),
            byte_end: byte_of(relative_end),
        }
    }

    /// The remainder of this token after `prefix`, or `None` when `prefix`
    /// already covers it.
    fn tail_after(&self, prefix: &DocToken) -> Option<DocToken> {
        (prefix.char_end < self.char_end).then_some(DocToken {
            char_start: prefix.char_end,
            char_end: self.char_end,
            byte_start: prefix.byte_end,
            byte_end: self.byte_end,
        })
    }
}

/// Tokenize `content` into [`DocToken`] spans.
///
/// Same token boundaries as [`tokenize_words`] — alphanumeric runs and
/// non-whitespace punctuation runs, whitespace as a separator — but it
/// allocates only the span vector. Used on the document side of highlighting,
/// where contents can be megabytes.
pub(crate) fn tokenize_doc_spans(content: &str) -> Vec<DocToken> {
    let mut tokens = Vec::new();
    let mut chars = content.char_indices().enumerate().peekable();

    while let Some((char_index, (byte_index, ch))) = chars.next() {
        if ch.is_whitespace() {
            continue;
        }

        let is_word = ch.is_alphanumeric();
        let char_start = char_index;
        let byte_start = byte_index;
        let mut char_end = char_index + 1;
        let mut byte_end = byte_index + ch.len_utf8();

        while let Some(&(next_char_index, (next_byte_index, next_ch))) = chars.peek() {
            if next_ch.is_whitespace() || next_ch.is_alphanumeric() != is_word {
                break;
            }
            char_end = next_char_index + 1;
            byte_end = next_byte_index + next_ch.len_utf8();
            chars.next();
        }

        tokens.push(DocToken {
            char_start,
            char_end,
            byte_start,
            byte_end,
        });
    }

    tokens
}

/// Context for highlighting a candidate document.
pub(crate) struct HighlightContext<'a> {
    pub content: &'a str,
    pub doc_words: &'a [DocToken],
    pub query_words: &'a [&'a str],
    pub last_word_is_prefix: bool,
}

/// Highlight a candidate using the same word-matching criteria as ranking
/// (exact, prefix, substring, fuzzy edit-distance) via `does_word_match`. This ensures
/// what's highlighted matches what was ranked in Phase 2 bucket scoring.
///
/// `doc_words` is pre-computed in Phase 2 to avoid redundant tokenization
/// (~4000 allocations per search); folding happens per token here.
///
/// For large documents (>32KB), uses fast matching (exact + prefix only)
/// to avoid expensive fuzzy/subsequence matching.
pub(crate) fn highlight_candidate(ctx: &HighlightContext<'_>) -> FuzzyMatch {
    // Highlights carry the byte span alongside the char span so the bridging
    // pass can read the intervening text directly from `content` instead of
    // materializing the whole document as a `Vec<char>`.
    let mut word_highlights: Vec<(DocToken, HighlightKind)> = Vec::new();
    let mut matched_query_words = vec![false; ctx.query_words.len()];

    let query_folded: Vec<String> = ctx.query_words.iter().map(|w| fold_str(w)).collect();
    // Use fast matching for large documents
    let is_large_doc = ctx.content.len() > LARGE_DOC_THRESHOLD_BYTES;

    for token in ctx.doc_words {
        let doc_word = token.text(ctx.content);
        let doc_word_folded = fold_str(doc_word);
        for (qi, qw) in query_folded.iter().enumerate() {
            let prefix_match =
                prefix_match_for_query_word(query_folded.len(), qi, ctx.last_word_is_prefix);
            let wmk = if is_large_doc {
                does_word_match_fast(qw, &doc_word_folded, prefix_match)
            } else {
                does_word_match(qw, &doc_word_folded, doc_word, prefix_match)
            };
            if wmk != WordMatchKind::None {
                matched_query_words[qi] = true;
                // Only highlight word tokens directly. Punctuation tokens (match_weight=0)
                // are included via the bridging pass when they fall between word highlights,
                // preventing random punctuation elsewhere from being highlighted.
                if is_word_token(qw) {
                    append_word_highlight(&mut word_highlights, ctx.content, *token, wmk);
                }
                break; // Don't double-highlight from multiple query words
            }
        }
    }

    // Sort by start position
    word_highlights.sort_unstable_by_key(|(token, _)| token.char_start);

    // Bridge gaps between adjacent highlighted ranges where intervening chars are all
    // non-whitespace punctuation or ranges are directly adjacent (e.g. "://" in URLs,
    // "." in domains, "/" in paths). Inherit the first range's kind.
    let mut bridged: Vec<(DocToken, HighlightKind)> = Vec::with_capacity(word_highlights.len());
    for wh in &word_highlights {
        if let Some(last) = bridged.last_mut() {
            let gap_start = last.0.byte_end;
            let gap_end = wh.0.byte_start;
            if gap_start <= gap_end
                && gap_end <= ctx.content.len()
                && should_bridge_highlights(last.1, wh.1, &ctx.content[gap_start..gap_end])
            {
                // Merge into previous range, inheriting its kind
                last.0.char_end = wh.0.char_end;
                last.0.byte_end = wh.0.byte_end;
                continue;
            }
        }
        bridged.push(*wh);
    }

    // Convert to HighlightRange
    let highlight_ranges: Vec<HighlightRange> = bridged
        .iter()
        .map(|(token, kind)| HighlightRange {
            start: token.char_start as u64,
            end: token.char_end as u64,
            kind: *kind,
        })
        .collect();

    FuzzyMatch { highlight_ranges }
}

/// Convert matched indices to highlight ranges with a specified kind
#[cfg(test)]
fn indices_to_ranges_with_kind(indices: &[u32], kind: HighlightKind) -> Vec<HighlightRange> {
    if indices.is_empty() {
        return Vec::new();
    }

    let mut sorted = indices.to_vec();
    sorted.sort_unstable();
    sorted.dedup();

    sorted[1..]
        .iter()
        .fold(vec![(sorted[0], sorted[0] + 1)], |mut acc, &idx| {
            let last = acc.last_mut().unwrap();
            if idx == last.1 {
                last.1 = idx + 1;
            } else {
                acc.push((idx, idx + 1));
            }
            acc
        })
        .into_iter()
        .map(|(start, end)| HighlightRange {
            start: start as u64,
            end: end as u64,
            kind,
        })
        .collect()
}

/// Convert matched indices to highlight ranges (defaults to Exact kind)
#[cfg(test)]
fn indices_to_ranges(indices: &[u32]) -> Vec<HighlightRange> {
    indices_to_ranges_with_kind(indices, HighlightKind::Exact)
}

/// Find the highlight in the densest cluster of highlights using a sliding window.
const EARLIER_CLUSTER_COVERAGE_TOLERANCE: u64 = 2;
const EARLIER_CLUSTER_MATCH_SCORE_TOLERANCE: u64 = 1;

pub(crate) fn find_densest_highlight(
    highlights: &[HighlightRange],
    window_size: u64,
) -> Option<usize> {
    if highlights.is_empty() {
        return None;
    }

    let mut indexed: Vec<(usize, &HighlightRange)> = highlights
        .iter()
        .enumerate()
        .filter(|(_, h)| !matches!(h.kind, HighlightKind::PrefixTail))
        .collect();

    if indexed.is_empty() {
        return Some(0);
    }
    if indexed.len() == 1 {
        return Some(indexed[0].0);
    }
    indexed.sort_by_key(|(_, h)| h.start);

    let mut left = 0;
    let mut best_left = 0;
    let mut best_coverage = 0u64;
    let mut best_anchor_score = 0u64;
    let mut current_coverage = 0u64;

    for right in 0..indexed.len() {
        while indexed[left].1.start + window_size <= indexed[right].1.start {
            current_coverage -= indexed[left].1.end - indexed[left].1.start;
            left += 1;
        }
        current_coverage += indexed[right].1.end - indexed[right].1.start;

        let current_start = indexed[left].1.start;
        let current_anchor_score = highlight_match_score(indexed[left].1.kind);
        let best_start = indexed[best_left].1.start;

        if cluster_beats_best(
            current_coverage,
            current_anchor_score,
            current_start,
            best_coverage,
            best_anchor_score,
            best_start,
        ) {
            best_coverage = current_coverage;
            best_anchor_score = current_anchor_score;
            best_left = left;
        }
    }

    Some(indexed[best_left].0)
}

fn highlight_match_score(kind: HighlightKind) -> u64 {
    match kind {
        HighlightKind::Exact => 6,
        HighlightKind::Prefix => 5,
        HighlightKind::PrefixTail => 0,
        HighlightKind::SubwordPrefix => 4,
        HighlightKind::Substring => 3,
        HighlightKind::Fuzzy => 2,
        HighlightKind::Subsequence => 1,
    }
}

fn cluster_beats_best(
    current_coverage: u64,
    current_anchor_score: u64,
    current_start: u64,
    best_coverage: u64,
    best_anchor_score: u64,
    best_start: u64,
) -> bool {
    if current_coverage > best_coverage + EARLIER_CLUSTER_COVERAGE_TOLERANCE {
        return true;
    }
    if current_coverage + EARLIER_CLUSTER_COVERAGE_TOLERANCE < best_coverage {
        return false;
    }

    if current_anchor_score > best_anchor_score + EARLIER_CLUSTER_MATCH_SCORE_TOLERANCE {
        return true;
    }
    if current_anchor_score + EARLIER_CLUSTER_MATCH_SCORE_TOLERANCE < best_anchor_score {
        return false;
    }

    current_start < best_start
}

/// Generate a generous text snippet around the densest cluster of highlights.
pub(crate) fn generate_snippet(
    content: &str,
    highlights: &[HighlightRange],
    max_len: usize,
) -> (String, Vec<HighlightRange>, u64) {
    let policy = ExcerptPolicy {
        whitespace_mode: WhitespaceMode::CollapseAll,
        max_chars: max_len,
        context_chars: SNIPPET_CONTEXT_CHARS,
        leading_context_chars: SNIPPET_CONTEXT_CHARS,
        max_leading_line_breaks: None,
    };
    generate_snippet_with_policy(content, highlights, &policy)
}

/// Generate a text snippet using a presentation-profile-driven policy.
pub(crate) fn generate_snippet_with_policy(
    content: &str,
    highlights: &[HighlightRange],
    policy: &ExcerptPolicy,
) -> (String, Vec<HighlightRange>, u64) {
    let max_len = policy.max_chars;
    let content_char_len = content.chars().count();

    if highlights.is_empty() {
        let (preview, _) = normalize_snippet_with_mapping_ws(
            content,
            0,
            content_char_len,
            max_len,
            policy.whitespace_mode,
        );
        return (preview, Vec::new(), 0);
    }

    let density_window = policy.context_chars as u64;
    let center_idx = find_densest_highlight(highlights, density_window).unwrap_or(0);
    let center_highlight = &highlights[center_idx];
    let match_start_char = center_highlight.start as usize;
    let match_end_char = center_highlight.end as usize;

    let line_number = content
        .chars()
        .take(match_start_char.min(content_char_len))
        .filter(|&c| c == '\n')
        .count() as u64
        + 1;

    let match_char_len = match_end_char.saturating_sub(match_start_char);
    let remaining_space = max_len.saturating_sub(match_char_len);

    let context_before = (remaining_space / 2)
        .min(policy.leading_context_chars)
        .min(match_start_char);
    let context_after =
        (remaining_space - context_before).min(content_char_len.saturating_sub(match_end_char));

    let mut snippet_start_char = match_start_char - context_before;
    let snippet_end_char = (match_end_char + context_after).min(content_char_len);

    if snippet_start_char > 0 {
        let search_start_char = snippet_start_char.saturating_sub(10);
        let search_range: String = content
            .chars()
            .skip(search_start_char)
            .take(snippet_start_char - search_start_char)
            .collect();
        if let Some(space_pos) = search_range.rfind(char::is_whitespace) {
            if search_range.is_char_boundary(space_pos) {
                let char_offset = search_range[..space_pos].chars().count();
                let new_start = search_start_char + char_offset + 1;
                if new_start <= match_start_char.saturating_sub(context_before) {
                    snippet_start_char = new_start;
                }
            }
        }
    }

    if let Some(max_breaks) = policy.max_leading_line_breaks {
        snippet_start_char =
            clamp_leading_line_breaks(content, snippet_start_char, match_start_char, max_breaks);
    }

    let ellipsis_reserve = (if snippet_start_char > 0 { 1 } else { 0 })
        + (if snippet_end_char < content_char_len {
            1
        } else {
            0
        });
    let effective_max_len = max_len.saturating_sub(ellipsis_reserve);
    let (normalized_snippet, pos_map) = normalize_snippet_with_mapping_ws(
        content,
        snippet_start_char,
        snippet_end_char,
        effective_max_len,
        policy.whitespace_mode,
    );

    let truncated_from_start = snippet_start_char > 0;
    let truncated_from_end = snippet_end_char < content_char_len;

    let prefix_offset = if truncated_from_start { 1 } else { 0 };
    let mut final_snippet = if truncated_from_start {
        format!("\u{2026}{}", normalized_snippet)
    } else {
        normalized_snippet.clone()
    };
    if truncated_from_end {
        final_snippet.push('\u{2026}');
    }

    let adjusted_highlights: Vec<HighlightRange> = highlights
        .iter()
        .filter_map(|h| {
            let orig_start = (h.start as usize).checked_sub(snippet_start_char)?;
            let orig_end = (h.end as usize).saturating_sub(snippet_start_char);

            let norm_start = map_position(orig_start, &pos_map)?;
            let norm_end = map_position(orig_end, &pos_map).unwrap_or(normalized_snippet.len());

            if norm_start < normalized_snippet.len() {
                Some(HighlightRange {
                    start: (norm_start + prefix_offset) as u64,
                    end: (norm_end.min(normalized_snippet.len()) + prefix_offset) as u64,
                    kind: h.kind,
                })
            } else {
                None
            }
        })
        .collect();

    (final_snippet, adjusted_highlights, line_number)
}

/// Advance the snippet window start so at most `max_line_breaks` hard line
/// breaks remain before the match, keeping the partial line before the kept
/// breaks. Raw newline count is an upper bound on the normalized count
/// (PreserveLineBreaks only collapses runs), so the cap holds in the final
/// excerpt. The start only moves forward and the clamp runs before
/// normalization and highlight remapping, so downstream offsets stay correct.
fn clamp_leading_line_breaks(
    content: &str,
    window_start_char: usize,
    match_start_char: usize,
    max_line_breaks: usize,
) -> usize {
    let lead_len = match_start_char.saturating_sub(window_start_char);
    let break_positions: Vec<usize> = content
        .chars()
        .enumerate()
        .skip(window_start_char)
        .take(lead_len)
        .filter(|&(_, c)| c == '\n')
        .map(|(pos, _)| pos)
        .collect();

    let mut start = window_start_char;
    if break_positions.len() > max_line_breaks {
        start = break_positions[break_positions.len() - 1 - max_line_breaks] + 1;
    }
    // A window starting on '\n' would render as an ellipsis-only first line;
    // skip past any blank-line run.
    while start < match_start_char && break_positions.binary_search(&start).is_ok() {
        start += 1;
    }
    start
}

/// Create a matched excerpt from full-content scalar highlights, using a presentation profile.
pub(crate) fn create_matched_excerpt(
    content: &str,
    highlights: &[HighlightRange],
    profile: ListPresentationProfile,
) -> MatchedExcerpt {
    let policy = ExcerptPolicy::for_profile(profile);
    let (text, adjusted_highlights, line_number) =
        generate_snippet_with_policy(content, highlights, &policy);
    let highlights = scalar_highlights_to_utf16(&text, &adjusted_highlights);

    MatchedExcerpt {
        text,
        highlights,
        line_number,
    }
}

/// Create preview decoration from scalar full-content highlights.
pub(crate) fn create_preview_decoration(
    content: &str,
    analysis: &HighlightAnalysis,
) -> PreviewDecoration {
    let (highlights, initial_scroll_highlight_index) = limit_preview_highlights(
        analysis,
        PreviewHighlightLimit::FocusedWindow {
            max_highlights: PREVIEW_MAX_HIGHLIGHTS,
            context_chars: PREVIEW_HIGHLIGHT_CONTEXT_CHARS,
        },
    );
    PreviewDecoration {
        highlights: scalar_highlights_to_utf16(content, &highlights),
        initial_scroll_highlight_index,
    }
}

pub(crate) fn create_preview_decoration_with_char_offset(
    content: &str,
    analysis: &HighlightAnalysis,
    char_offset: usize,
) -> PreviewDecoration {
    let (focused_highlights, initial_scroll_highlight_index) = limit_preview_highlights(
        analysis,
        PreviewHighlightLimit::FocusedWindow {
            max_highlights: PREVIEW_MAX_HIGHLIGHTS,
            context_chars: PREVIEW_HIGHLIGHT_CONTEXT_CHARS,
        },
    );
    let shifted_highlights: Vec<HighlightRange> = focused_highlights
        .iter()
        .map(|highlight| HighlightRange {
            start: highlight.start + char_offset as u64,
            end: highlight.end + char_offset as u64,
            kind: highlight.kind,
        })
        .collect();

    PreviewDecoration {
        highlights: scalar_highlights_to_utf16(content, &shifted_highlights),
        initial_scroll_highlight_index,
    }
}

fn short_query_highlights(content: &str, query: &str, prefer_prefix: bool) -> Vec<HighlightRange> {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }

    // fold_str is 1:1 per char, so a char index computed on the folded string
    // is valid in the original content (byte indices are not interchangeable).
    let content_folded = fold_str(content);
    let query_folded = fold_str(trimmed);
    let query_char_len = trimmed.chars().count();

    let start = if prefer_prefix && content_folded.starts_with(&query_folded) {
        Some(0)
    } else {
        content_folded
            .find(&query_folded)
            .map(|byte_idx| content_folded[..byte_idx].chars().count())
    };

    start
        .map(|start| HighlightRange {
            start: start as u64,
            end: (start + query_char_len) as u64,
            kind: if start == 0 && prefer_prefix {
                HighlightKind::Prefix
            } else {
                HighlightKind::Exact
            },
        })
        .into_iter()
        .collect()
}

fn compute_scalar_highlights(content: &str, query: &str) -> Vec<HighlightRange> {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }

    if trimmed.chars().count() < MIN_TRIGRAM_QUERY_LEN {
        return short_query_highlights(content, trimmed, true);
    }

    if is_symbol_bearing_query(trimmed) {
        let literal_highlights = short_query_highlights(content, trimmed, true);
        if !literal_highlights.is_empty() {
            return literal_highlights;
        }
    }

    let query_words_owned = tokenize_words(trimmed);
    let query_words: Vec<&str> = query_words_owned
        .iter()
        .map(|(_, _, w)| w.as_str())
        .collect();
    let last_word_is_prefix = trimmed.ends_with(|c: char| c.is_alphanumeric());

    let scanned = highlight_scan_window(content);
    let doc_words = tokenize_doc_spans(scanned);

    // Create a temporary FuzzyMatch to reuse highlight_candidate
    let fm = highlight_candidate(&HighlightContext {
        content: scanned,
        doc_words: &doc_words,
        query_words: &query_words,
        last_word_is_prefix,
    });

    fm.highlight_ranges
}

/// Leading slice of `content` that highlighting scans.
///
/// Highlighting is a presentation concern: the excerpt and the preview's
/// initial scroll target both come from the earliest dense cluster of matches,
/// so highlights past this window can never be shown. Capping the scan keeps a
/// pathological multi-megabyte clip from costing time and memory proportional
/// to its full length on every keystroke, while leaving every realistic clip
/// (and the entire chunk a large item was recalled through) fully scanned.
///
/// The cut lands on a char boundary, so the returned slice is always valid and
/// char offsets into it match offsets into `content`.
fn highlight_scan_window(content: &str) -> &str {
    if content.len() <= HIGHLIGHT_SCAN_LIMIT_BYTES {
        return content;
    }
    let mut end = HIGHLIGHT_SCAN_LIMIT_BYTES;
    while end > 0 && !content.is_char_boundary(end) {
        end -= 1;
    }
    &content[..end]
}

pub(crate) fn analyze_content_for_query(content: &str, query: &str) -> Option<HighlightAnalysis> {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return None;
    }

    let highlights = compute_scalar_highlights(content, trimmed);
    let initial_scroll_highlight_index =
        find_densest_highlight(&highlights, SNIPPET_CONTEXT_CHARS as u64).map(|idx| idx as u64);

    Some(HighlightAnalysis {
        highlights,
        initial_scroll_highlight_index,
    })
}

/// Lightweight word-match-only analysis for Phase 1-only (tail) items.
///
/// Small contents (<= 32KB) honor all ranking match classes via
/// `does_word_match`, so scan-rescued tail items visibly show why they
/// matched; larger contents keep exact + prefix matching only (via
/// `does_word_match_fast_raw`) for performance, mirroring Phase 2's
/// large-doc policy.
pub(crate) fn analyze_content_word_match(content: &str, query: &str) -> Option<HighlightAnalysis> {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return None;
    }

    let highlights = compute_word_match_highlights(content, trimmed);
    let initial_scroll_highlight_index =
        find_densest_highlight(&highlights, SNIPPET_CONTEXT_CHARS as u64).map(|idx| idx as u64);

    Some(HighlightAnalysis {
        highlights,
        initial_scroll_highlight_index,
    })
}

/// Compute highlights using per-word matching.
///
/// For each query word, finds all matching document words and emits highlight
/// ranges. Contents up to `LARGE_DOC_THRESHOLD_BYTES` honor every ranking
/// match class (exact, prefix, subword, infix, fuzzy, subsequence); larger
/// contents produce only `Exact` and `Prefix` kinds for performance.
fn compute_word_match_highlights(content: &str, query: &str) -> Vec<HighlightRange> {
    if is_symbol_bearing_query(query) {
        let literal_highlights = short_query_highlights(content, query, true);
        if !literal_highlights.is_empty() {
            return literal_highlights;
        }
    }

    let query_words_owned = tokenize_words(query);
    let query_words: Vec<&str> = query_words_owned
        .iter()
        .map(|(_, _, w)| w.as_str())
        .collect();
    let last_word_is_prefix = query.ends_with(|c: char| c.is_alphanumeric());

    let content = highlight_scan_window(content);
    let doc_words = tokenize_doc_spans(content);
    let query_folded: Vec<String> = query_words.iter().map(|w| fold_str(w)).collect();
    let use_full_matching = content.len() <= LARGE_DOC_THRESHOLD_BYTES;

    let mut highlights: Vec<(DocToken, HighlightKind)> = Vec::new();

    for token in &doc_words {
        let doc_word = token.text(content);
        if !is_word_token(doc_word) {
            continue;
        }
        let doc_word_folded = use_full_matching.then(|| fold_str(doc_word));
        for (qi, qw_folded) in query_folded.iter().enumerate() {
            if !is_word_token(&query_words[qi]) {
                continue;
            }
            let prefix_match =
                prefix_match_for_query_word(query_folded.len(), qi, last_word_is_prefix);
            let wmk = match &doc_word_folded {
                Some(dw_folded) => does_word_match(qw_folded, dw_folded, doc_word, prefix_match),
                None => does_word_match_fast_raw(qw_folded, doc_word, prefix_match),
            };
            if wmk != WordMatchKind::None {
                append_word_highlight(&mut highlights, content, *token, wmk);
                break;
            }
        }
    }

    highlights.sort_unstable_by_key(|(token, _)| token.char_start);

    highlights
        .into_iter()
        .map(|(token, kind)| HighlightRange {
            start: token.char_start as u64,
            end: token.char_end as u64,
            kind,
        })
        .collect()
}

/// Compute a matched excerpt for an item given a query and presentation profile.
pub(crate) fn compute_matched_excerpt(
    content: &str,
    query: &str,
    profile: ListPresentationProfile,
) -> MatchedExcerpt {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        let policy = ExcerptPolicy::for_profile(profile);
        let (text, _, _) = generate_snippet_with_policy(content, &[], &policy);
        return MatchedExcerpt {
            text,
            highlights: Vec::new(),
            line_number: 0,
        };
    }

    let analysis =
        analyze_content_for_query(content, trimmed).expect("non-empty query should analyze");
    create_matched_excerpt(content, &analysis.highlights, profile)
}

/// Tokenize text into tokens with char offsets.
/// Produces both alphanumeric word tokens and non-whitespace punctuation tokens.
/// Whitespace is skipped (acts as a separator).
/// Punctuation tokens allow matching symbols like "://", ".", "/" in URLs/paths.
pub(crate) fn tokenize_words(content: &str) -> Vec<(usize, usize, String)> {
    let chars: Vec<char> = content.chars().collect();
    let mut tokens = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i].is_whitespace() {
            i += 1;
            continue;
        }
        let start = i;
        if chars[i].is_alphanumeric() {
            while i < chars.len() && chars[i].is_alphanumeric() {
                i += 1;
            }
        } else {
            while i < chars.len() && !chars[i].is_alphanumeric() && !chars[i].is_whitespace() {
                i += 1;
            }
        }
        let token: String = chars[start..i].iter().collect();
        tokens.push((start, i, token));
    }
    tokens
}

/// Whether a token from `tokenize_words` is an alphanumeric word (vs punctuation).
/// Tokens are homogeneous runs — either all alphanumeric or all punctuation —
/// so checking the first character is sufficient.
pub(crate) fn is_word_token(token: &str) -> bool {
    token.starts_with(|c: char| c.is_alphanumeric())
}

pub(crate) fn is_symbol_bearing_query(query: &str) -> bool {
    query
        .chars()
        .any(|character| !character.is_alphanumeric() && !character.is_whitespace())
}

fn normalize_snippet_with_mapping_ws(
    content: &str,
    start: usize,
    end: usize,
    max_chars: usize,
    ws_mode: WhitespaceMode,
) -> (String, Vec<usize>) {
    if end <= start {
        return (String::new(), vec![0]);
    }

    let mut result = String::with_capacity(max_chars);
    let mut pos_map = Vec::with_capacity(end - start + 1);
    let mut last_was_space = false;
    let mut consecutive_newlines: usize = 0;
    let mut norm_idx = 0;

    for ch in content.chars().skip(start).take(end - start) {
        pos_map.push(norm_idx);

        if norm_idx >= max_chars {
            continue;
        }

        match ws_mode {
            WhitespaceMode::CollapseAll => {
                let ch = match ch {
                    '\n' | '\t' | '\r' => ' ',
                    c => c,
                };
                if ch == ' ' {
                    if last_was_space {
                        continue;
                    }
                    last_was_space = true;
                } else {
                    last_was_space = false;
                }
                result.push(ch);
                norm_idx += 1;
            }
            WhitespaceMode::PreserveLineBreaks => {
                if ch == '\n' {
                    consecutive_newlines += 1;
                    last_was_space = false;
                    // Collapse 3+ newlines into 2 (one blank line)
                    if consecutive_newlines <= 2 {
                        result.push('\n');
                        norm_idx += 1;
                    }
                    continue;
                }
                if ch == '\r' {
                    // Skip carriage returns entirely
                    continue;
                }
                consecutive_newlines = 0;
                let ch = match ch {
                    '\t' => ' ',
                    c => c,
                };
                if ch == ' ' {
                    if last_was_space {
                        continue;
                    }
                    last_was_space = true;
                } else {
                    last_was_space = false;
                }
                result.push(ch);
                norm_idx += 1;
            }
        }
    }

    pos_map.push(norm_idx);

    // Trim trailing whitespace
    while result.ends_with(' ') || result.ends_with('\n') {
        result.pop();
    }

    (result, pos_map)
}

fn map_position(orig_pos: usize, pos_map: &[usize]) -> Option<usize> {
    pos_map.get(orig_pos).copied()
}

/// Generate a preview from content (no highlights, starts from beginning).
/// Uses CollapseAll whitespace mode (compact row behavior).
pub fn generate_preview(content: &str, max_chars: usize) -> String {
    let trimmed = content.trim_start();
    let (preview, _, _) = generate_snippet(trimmed, &[], max_chars);
    preview
}

/// Generate a preview using a presentation profile's excerpt policy.
pub fn generate_preview_for_profile(content: &str, profile: ListPresentationProfile) -> String {
    let trimmed = content.trim_start();
    let policy = ExcerptPolicy::for_profile(profile);
    let (preview, _, _) = generate_snippet_with_policy(trimmed, &[], &policy);
    preview
}

/// Format a snippet for optimistic updates (e.g. after an edit).
/// Exposed via UniFFI so Swift doesn't need to invent its own truncation.
pub fn format_excerpt(content: &str, profile: ListPresentationProfile) -> String {
    generate_preview_for_profile(content, profile)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_indices_to_ranges() {
        let indices = vec![0, 1, 2, 5, 6, 10];
        let ranges = super::indices_to_ranges(&indices);
        assert_eq!(ranges.len(), 3);
        assert_eq!(
            ranges[0],
            HighlightRange {
                start: 0,
                end: 3,
                kind: HighlightKind::Exact
            }
        );
        assert_eq!(
            ranges[1],
            HighlightRange {
                start: 5,
                end: 7,
                kind: HighlightKind::Exact
            }
        );
        assert_eq!(
            ranges[2],
            HighlightRange {
                start: 10,
                end: 11,
                kind: HighlightKind::Exact
            }
        );
    }

    /// Helper: create a HighlightRange with Exact kind (for tests that don't care about kind)
    fn hr(start: u64, end: u64) -> HighlightRange {
        HighlightRange {
            start,
            end,
            kind: HighlightKind::Exact,
        }
    }

    #[test]
    fn test_word_match_highlights_include_substring_and_fuzzy_for_small_content() {
        let substring = super::compute_word_match_highlights("clipboard manager", "board");
        assert!(
            substring
                .iter()
                .any(|h| h.kind == HighlightKind::Substring && h.start == 4 && h.end == 9),
            "'board' should highlight its infix inside 'clipboard', got {:?}",
            substring
        );

        let fuzzy = super::compute_word_match_highlights("clipboard manager", "managr");
        assert!(
            fuzzy.iter().any(|h| h.kind == HighlightKind::Fuzzy),
            "typo'd 'managr' should highlight 'manager' on small content, got {:?}",
            fuzzy
        );

        // LargeFast parity: above 32KB only exact + prefix kinds survive.
        let large_content = format!("clipboard manager {}", "filler ".repeat(5_000));
        assert!(large_content.len() > LARGE_DOC_THRESHOLD_BYTES);
        let large = super::compute_word_match_highlights(&large_content, "board");
        assert!(
            large.is_empty(),
            "large contents keep exact + prefix matching only, got {:?}",
            large
        );
    }

    #[test]
    fn test_generate_snippet_basic() {
        let content = "This is a long text with some interesting content that we want to highlight";
        let highlights = vec![hr(28, 39)];
        let (snippet, adj_highlights, _line) = super::generate_snippet(content, &highlights, 50);
        assert!(snippet.contains("interesting"));
        assert!(!adj_highlights.is_empty());
    }

    #[test]
    fn test_snippet_contains_match_mid_content() {
        let content = "The quick brown fox jumps over the lazy dog and runs away fast";
        let highlights = vec![hr(35, 39)];
        let (snippet, adj_highlights, _) = super::generate_snippet(content, &highlights, 30);
        assert!(snippet.contains("lazy"), "Snippet should contain the match");
        assert!(!adj_highlights.is_empty());
        let h = &adj_highlights[0];
        let highlighted: String = snippet
            .chars()
            .skip(h.start as usize)
            .take((h.end - h.start) as usize)
            .collect();
        assert_eq!(highlighted, "lazy");
    }

    #[test]
    fn test_snippet_match_at_start() {
        let content = "Hello world";
        let highlights = vec![hr(0, 5)];
        let (snippet, adj_highlights, _) = super::generate_snippet(content, &highlights, 50);
        assert_eq!(adj_highlights[0].start, 0, "Highlight should start at 0");
        assert_eq!(snippet, "Hello world");
    }

    #[test]
    fn test_snippet_normalizes_whitespace() {
        let content = "Line one\n\nLine two";
        let highlights = vec![hr(0, 4)];
        let (snippet, adj_highlights, _) = super::generate_snippet(content, &highlights, 50);
        assert!(!snippet.contains('\n'));
        assert!(!snippet.contains("  "));
        let h = &adj_highlights[0];
        let highlighted: String = snippet
            .chars()
            .skip(h.start as usize)
            .take((h.end - h.start) as usize)
            .collect();
        assert_eq!(highlighted, "Line");
    }

    #[test]
    fn test_snippet_highlight_adjustment_long_content() {
        let content = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaTARGET text here";
        let highlights = vec![hr(46, 52)];
        let (snippet, adj_highlights, _) = super::generate_snippet(content, &highlights, 30);
        assert!(snippet.contains("TARGET"));
        let h = &adj_highlights[0];
        let highlighted: String = snippet
            .chars()
            .skip(h.start as usize)
            .take((h.end - h.start) as usize)
            .collect();
        assert_eq!(highlighted, "TARGET");
    }

    #[test]
    fn test_snippet_very_long_content() {
        let long_prefix = "a".repeat(100);
        let long_suffix = "z".repeat(100);
        let content = format!("{}MATCH{}", long_prefix, long_suffix);
        let highlights = vec![hr(100, 105)];
        let (snippet, adj_highlights, _) = super::generate_snippet(&content, &highlights, 30);
        assert!(snippet.contains("MATCH"));
        let h = &adj_highlights[0];
        let highlighted: String = snippet
            .chars()
            .skip(h.start as usize)
            .take((h.end - h.start) as usize)
            .collect();
        assert_eq!(highlighted, "MATCH");
    }

    #[test]
    fn test_snippet_utf8_multibyte_chars() {
        let content = "Hello \u{4f60}\u{597d} world \u{1f30d} test";
        let highlights = vec![hr(6, 8)];
        let (snippet, adj_highlights, _) = super::generate_snippet(content, &highlights, 50);
        assert!(snippet.contains("\u{4f60}\u{597d}"));
        assert!(!adj_highlights.is_empty());
        let h = &adj_highlights[0];
        let highlighted: String = snippet
            .chars()
            .skip(h.start as usize)
            .take((h.end - h.start) as usize)
            .collect();
        assert_eq!(highlighted, "\u{4f60}\u{597d}");
    }

    // ── Word-level highlighting tests (using does_word_match) ────

    #[test]
    fn test_tokenize_words() {
        // Whitespace-separated words
        let words = tokenize_words("hello world");
        assert_eq!(words, vec![(0, 5, "hello".into()), (6, 11, "world".into())]);

        // Punctuation produces separate tokens
        let words = tokenize_words("urlparser.parse(input)");
        assert_eq!(
            words,
            vec![
                (0, 9, "urlparser".into()),
                (9, 10, ".".into()),
                (10, 15, "parse".into()),
                (15, 16, "(".into()),
                (16, 21, "input".into()),
                (21, 22, ")".into()),
            ]
        );

        // Consecutive punctuation forms one token
        let words = tokenize_words("one--two...three");
        assert_eq!(
            words,
            vec![
                (0, 3, "one".into()),
                (3, 5, "--".into()),
                (5, 8, "two".into()),
                (8, 11, "...".into()),
                (11, 16, "three".into()),
            ]
        );

        // URL tokenization preserves :// as a token
        let words = tokenize_words("https://github.com");
        assert_eq!(
            words,
            vec![
                (0, 5, "https".into()),
                (5, 8, "://".into()),
                (8, 14, "github".into()),
                (14, 15, ".".into()),
                (15, 18, "com".into()),
            ]
        );
    }

    #[test]
    fn tokenize_doc_spans_matches_tokenize_words() {
        // `tokenize_doc_spans` is the zero-copy replacement for `tokenize_words`
        // on the document side of highlighting. Highlight offsets are char
        // offsets, so the char spans must agree exactly, and slicing by the byte
        // span must reproduce the token text — including for multi-byte input,
        // where char and byte offsets diverge.
        let cases = [
            "hello world",
            "urlparser.parse(input)",
            "one--two...three",
            "https://github.com",
            "",
            "   ",
            "a",
            ".",
            "café naïve",
            "日本語 テキスト",
            "emoji 🎉🎉 mix",
            "Ünïcödé--wörds...ok",
            "tab\there\nnewline",
            "trailing   ",
            "   leading",
            "a1b2c3!@#$xyz",
            "\u{4f60}\u{597d} world",
            "mixed🎉alnum",
        ];

        for case in cases {
            let expected = tokenize_words(case);
            let actual = super::tokenize_doc_spans(case);
            assert_eq!(
                expected.len(),
                actual.len(),
                "token count differs for {case:?}"
            );
            for (expected, actual) in expected.iter().zip(actual.iter()) {
                assert_eq!(
                    (expected.0, expected.1),
                    (actual.char_start, actual.char_end),
                    "char span differs for {case:?}"
                );
                assert_eq!(
                    expected.2.as_str(),
                    actual.text(case),
                    "token text differs for {case:?}"
                );
            }
        }
    }

    #[test]
    fn doc_token_subspan_keeps_char_and_byte_offsets_in_sync() {
        // A prefix match on a multi-byte token reports a char-relative span;
        // the byte offsets must follow it so the bridging pass reads the right
        // gap text.
        let content = "xx ünïcödé yy";
        let tokens = super::tokenize_doc_spans(content);
        let token = tokens[1];
        assert_eq!(token.text(content), "ünïcödé");

        let head = token.subspan(content, 0, 3);
        assert_eq!((head.char_start, head.char_end), (3, 6));
        assert_eq!(head.text(content), "ünï");

        let tail = token.tail_after(&head).expect("prefix leaves a tail");
        assert_eq!(tail.text(content), "cödé");
        assert_eq!((tail.char_start, tail.char_end), (6, 10));

        // A full-width span returns the token untouched.
        assert_eq!(token.subspan(content, 0, 99), token);
        assert!(token.tail_after(&token).is_none());
    }

    #[test]
    fn highlight_scan_window_caps_pathological_content_on_a_char_boundary() {
        let small = "short content";
        assert_eq!(super::highlight_scan_window(small), small);

        // Multi-byte filler so the cut lands mid-character without the
        // boundary walk.
        let huge = "é".repeat(super::HIGHLIGHT_SCAN_LIMIT_BYTES);
        let window = super::highlight_scan_window(&huge);
        assert!(window.len() <= super::HIGHLIGHT_SCAN_LIMIT_BYTES);
        assert!(window.len() > super::HIGHLIGHT_SCAN_LIMIT_BYTES - 4);
        // Valid UTF-8 slice made only of the filler char.
        assert!(window.chars().all(|c| c == 'é'));
    }

    #[test]
    fn highlights_survive_content_far_past_the_scan_window() {
        // A match inside the scanned window still highlights when the item is
        // much larger than the cap, and the offsets stay correct.
        let mut content = String::from("needle at the very start ");
        content.push_str(&"filler ".repeat(super::HIGHLIGHT_SCAN_LIMIT_BYTES / 7));
        let highlights = super::compute_scalar_highlights(&content, "needle");
        assert_eq!(highlights.len(), 1);
        assert_eq!((highlights[0].start, highlights[0].end), (0, 6));
    }

    /// Helper: call highlight_candidate with automatic lowercasing/tokenization.
    fn hc(
        _id: i64,
        content: &str,
        _timestamp: i64,
        _tantivy_score: f32,
        query_words: &[&str],
        last_word_is_prefix: bool,
    ) -> FuzzyMatch {
        let doc_words = super::tokenize_doc_spans(content);
        super::highlight_candidate(&super::HighlightContext {
            content,
            doc_words: &doc_words,
            query_words,
            last_word_is_prefix,
        })
    }

    fn highlighted_words(content: &str, query_words: &[&str]) -> Vec<String> {
        let fm = hc(1, content, 1000, 1.0, query_words, false);
        let chars: Vec<char> = content.chars().collect();
        fm.highlight_ranges
            .iter()
            .map(|r| chars[r.start as usize..r.end as usize].iter().collect())
            .collect()
    }

    #[test]
    fn test_highlight_exact_match() {
        let words = highlighted_words("hello world", &["hello"]);
        assert_eq!(words, vec!["hello"]);
    }

    #[test]
    fn test_highlight_typo_match() {
        let words = highlighted_words("Visit Riverside Park today", &["riversde"]);
        assert_eq!(words, vec!["Riverside"]);
    }

    #[test]
    fn test_highlight_prefix_match() {
        let fm = hc(1, "Run testing suite now", 1000, 1.0, &["test"], true);
        let chars: Vec<char> = "Run testing suite now".chars().collect();
        let words: Vec<String> = fm
            .highlight_ranges
            .iter()
            .map(|r| chars[r.start as usize..r.end as usize].iter().collect())
            .collect();
        assert_eq!(words, vec!["test", "ing"]);
        assert_eq!(fm.highlight_ranges[0].kind, HighlightKind::Prefix);
        assert_eq!(fm.highlight_ranges[1].kind, HighlightKind::PrefixTail);
    }

    #[test]
    fn test_highlight_single_char_prefix_match_for_multi_word_query() {
        let fm = hc(
            1,
            "recent changes to highlighting landed",
            1000,
            1.0,
            &["recent", "changes", "to", "h"],
            true,
        );

        assert!(fm.highlight_ranges.iter().any(|range| {
            range.kind == HighlightKind::Prefix && range.start == 18 && range.end == 19
        }));
        assert!(fm
            .highlight_ranges
            .iter()
            .any(|range| range.kind == HighlightKind::PrefixTail));
    }

    #[test]
    fn test_short_query_match_data_prefers_prefix() {
        let highlights = compute_scalar_highlights("Alpha beta", "al");
        assert_eq!(highlights.len(), 1);
        assert_eq!(highlights[0].start, 0);
        assert_eq!(highlights[0].end, 2);
        assert_eq!(highlights[0].kind, HighlightKind::Prefix);
    }

    #[test]
    fn test_short_query_match_data_finds_anywhere_substring() {
        let highlights = compute_scalar_highlights("zz Alpha beta", "ph");
        assert_eq!(highlights.len(), 1);
        assert_eq!(highlights[0].start, 5);
        assert_eq!(highlights[0].end, 7);
        assert_eq!(highlights[0].kind, HighlightKind::Exact);
    }

    #[test]
    fn test_highlight_subsequence_short_word() {
        // "helo" matches "hello" via subsequence (all chars in order)
        let words = highlighted_words("hello world", &["helo"]);
        assert_eq!(words, vec!["hello"]);
    }

    #[test]
    fn test_highlight_no_match_short_word() {
        // "hx" is too short for subsequence (< 3 chars) and no fuzzy for short words
        let words = highlighted_words("hello world", &["hx"]);
        assert!(words.is_empty());
    }

    #[test]
    fn test_highlight_multi_word() {
        let words = highlighted_words("hello beautiful world", &["hello", "world"]);
        assert_eq!(words, vec!["hello", "world"]);
    }

    #[test]
    fn test_highlight_short_exact_word() {
        let words = highlighted_words("hi there highway", &["hi"]);
        assert_eq!(words, vec!["hi"]);
    }

    #[test]
    fn test_highlight_multiple_occurrences() {
        let words = highlighted_words("hello world hello again", &["hello"]);
        assert_eq!(words, vec!["hello", "hello"]);
    }

    #[test]
    fn test_highlight_no_match() {
        let words = highlighted_words("hello world", &["xyz"]);
        assert!(words.is_empty());
    }

    // ── URL / special-character query tests ─────────────────────

    #[test]
    fn test_literal_symbol_query_highlights_complete_sequence() {
        assert_eq!(
            compute_scalar_highlights("/unit-testing-best-practices", "/unit"),
            vec![HighlightRange {
                start: 0,
                end: 5,
                kind: HighlightKind::Prefix,
            }]
        );
        assert_eq!(
            compute_word_match_highlights("https://example.com", "://"),
            vec![HighlightRange {
                start: 5,
                end: 8,
                kind: HighlightKind::Exact,
            }]
        );
    }

    #[test]
    fn test_highlight_url_query_bridges_punctuation() {
        // "http" prefix-matches "https" as a non-final query word; PrefixTail
        // blocks bridging, so the highlight honestly shows three ranges instead
        // of one bridged "https://github" run
        let words = highlighted_words("https://github.com/user/repo", &["http", "github"]);
        assert_eq!(words, vec!["http", "s", "github"]);
    }

    #[test]
    fn test_highlight_url_query_tokenized_from_raw() {
        // Simulate what search_trigram does: tokenize "http://github" into query words
        let query = "http://github";
        let query_words_owned = tokenize_words(query);
        let query_words: Vec<&str> = query_words_owned
            .iter()
            .map(|(_, _, w)| w.as_str())
            .collect();
        // Punctuation tokens are now real tokens in the query
        assert_eq!(query_words, vec!["http", "://", "github"]);

        let fm = hc(
            1,
            "https://github.com/user/repo",
            1000,
            1.0,
            &query_words,
            false,
        );
        let chars: Vec<char> = "https://github.com/user/repo".chars().collect();
        let words: Vec<String> = fm
            .highlight_ranges
            .iter()
            .map(|r| chars[r.start as usize..r.end as usize].iter().collect())
            .collect();
        // "http" prefix-matches "https" (Prefix + PrefixTail, never bridged);
        // "://" matches as a real token but punctuation is not highlighted directly
        assert_eq!(words, vec!["http", "s", "github"]);
    }

    #[test]
    fn test_highlight_non_final_prefix_match() {
        let fm = hc(1, "clipboard manager", 1000, 1.0, &["clip", "man"], true);
        let ranges: Vec<(u64, u64, HighlightKind)> = fm
            .highlight_ranges
            .iter()
            .map(|r| (r.start, r.end, r.kind))
            .collect();
        assert_eq!(
            ranges,
            vec![
                (0, 4, HighlightKind::Prefix),
                (4, 9, HighlightKind::PrefixTail),
                (10, 13, HighlightKind::Prefix),
                (13, 17, HighlightKind::PrefixTail),
            ]
        );
    }

    #[test]
    fn test_highlight_does_not_bridge_whitespace_gaps() {
        // Words separated by whitespace should NOT be bridged
        let words = highlighted_words("hello beautiful world", &["hello", "world"]);
        assert_eq!(words, vec!["hello", "world"]);
    }

    #[test]
    fn test_highlight_bridges_dots_in_domain() {
        // "github.com" → all three words bridged via dots
        let words = highlighted_words("https://github.com", &["github", "com"]);
        assert_eq!(words, vec!["github.com"]);
    }

    // ── Densest highlight cluster tests ──────────────────────────

    #[test]
    fn test_find_densest_highlight_empty() {
        assert_eq!(super::find_densest_highlight(&[], 500), None);
    }

    #[test]
    fn test_find_densest_highlight_single() {
        let highlights = vec![hr(50, 55)];
        assert_eq!(super::find_densest_highlight(&highlights, 500), Some(0));
    }

    #[test]
    fn test_find_densest_highlight_picks_denser_cluster() {
        let highlights = vec![hr(0, 5), hr(1000, 1005), hr(1050, 1055), hr(1100, 1105)];
        let idx = super::find_densest_highlight(&highlights, 500).unwrap();
        assert_eq!(highlights[idx].start, 1000);
    }

    #[test]
    fn test_find_densest_highlight_biases_earlier_when_clusters_are_close() {
        let highlights = vec![hr(0, 4), hr(1000, 1003), hr(1004, 1007)];
        let idx = super::find_densest_highlight(&highlights, 50).unwrap();
        assert_eq!(highlights[idx].start, 0);
    }

    #[test]
    fn test_find_densest_highlight_ignores_prefix_tail() {
        let highlights = vec![
            HighlightRange {
                start: 0,
                end: 4,
                kind: HighlightKind::Prefix,
            },
            HighlightRange {
                start: 4,
                end: 8,
                kind: HighlightKind::PrefixTail,
            },
            HighlightRange {
                start: 100,
                end: 105,
                kind: HighlightKind::Exact,
            },
        ];
        let idx = super::find_densest_highlight(&highlights, 50).unwrap();
        assert_eq!(idx, 0);
    }

    #[test]
    fn test_snippet_centers_on_densest_cluster() {
        let mut content = "a".repeat(10);
        content.push_str("LONE");
        content.push_str(&"b".repeat(986));
        content.push_str("DENSE1");
        content.push_str("xx");
        content.push_str("DENSE2");
        content.push_str("yy");
        content.push_str("DENSE3");
        content.push_str(&"c".repeat(100));

        let highlights = vec![hr(10, 14), hr(1000, 1006), hr(1008, 1014), hr(1016, 1022)];

        let (snippet, _, _) = super::generate_snippet(&content, &highlights, 100);
        assert!(
            snippet.contains("DENSE1"),
            "Snippet should center on densest cluster, got: {}",
            snippet
        );
        assert!(snippet.contains("DENSE2"));
    }

    // ── Real-world density regression tests ───────────────────────

    const NIX_BUILD_ERROR: &str = "\
    'path:./hosts/default'
  \u{2192} 'path:/Users/julsh/git/dotfiles/nix/hosts/local?lastModified=1770783424&narHash=sha256-I8uZtr2R0rm1z9UzZNkj/ofk%2B2mSNp7ElUS67Bhj7js%3D' (2026-02-11)
error: Cannot build '/nix/store/dsq2qkgpgq6nysisychilwx9gwpcg1i1-inetutils-2.7.drv'.
       Reason: builder failed with exit code 2.
       Output paths:
         /nix/store/n9yl2hqsljax4gabc7c1qbxbkb0j6l55-inetutils-2.7
         /nix/store/pk6z47v44zjv29y37rxdy8b6nszh8x8f-inetutils-2.7-apparmor
       Last 25 log lines:
       > openat-die.c:31:18: note: expanded from macro '_'
       >    31 | #define _(msgid) dgettext (GNULIB_TEXT_DOMAIN, msgid)
       >       |                  ^
       > ./gettext.h:127:39: note: expanded from macro 'dgettext'
       >   127 | #  define dgettext(Domainname, Msgid) ((void) (Domainname), gettext (Msgid))
       >       |                                       ^
       > ./error.h:506:39: note: expanded from macro 'error'
       >   506 |       __gl_error_call (error, status, __VA_ARGS__)
       >       |                                       ^
       > ./error.h:446:51: note: expanded from macro '__gl_error_call'
       >   446 |          __gl_error_call1 (function, __errstatus, __VA_ARGS__); \\
       >       |                                                   ^
       > ./error.h:431:26: note: expanded from macro '__gl_error_call1'
       >   431 |     ((function) (status, __VA_ARGS__), \\
       >       |                          ^
       > 4 errors generated.
       > make[4]: *** [Makefile:6332: libgnu_a-openat-die.o] Error 1
       > make[4]: Leaving directory '/nix/var/nix/builds/nix-55927-395412078/inetutils-2.7/lib'
       > make[3]: *** [Makefile:8385: all-recursive] Error 1
       > make[3]: Leaving directory '/nix/var/nix/builds/nix-55927-395412078/inetutils-2.7/lib'
       > make[2]: *** [Makefile:3747: all] Error 2
       > make[2]: Leaving directory '/nix/var/nix/builds/nix-55927-395412078/inetutils-2.7/lib'
       > make[1]: *** [Makefile:2630: all-recursive] Error 1
       > make[1]: Leaving directory '/nix/var/nix/builds/nix-55927-395412078/inetutils-2.7'
       > make: *** [Makefile:2567: all] Error 2
       For full logs, run:
         nix-store -l /nix/store/dsq2qkgpgq6nysisychilwx9gwpcg1i1-inetutils-2.7.drv
error: Cannot build '/nix/store/djv08y006z7jk69j2q9fq5f1ch195i4s-home-manager.drv'.
       Reason: 1 dependency failed.
       Output paths:
         /nix/store/67pn4ck72akj3bz7d131wdcz6w4gb5qb-home-manager
error: Build failed due to failed dependency";

    fn build_query_words(query: &str) -> Vec<String> {
        fold_str(query)
            .split_whitespace()
            .map(|s| s.to_string())
            .collect()
    }

    #[test]
    fn test_densest_highlight_prefers_exact_query_match_over_scattered_repeats() {
        let query_words_owned = build_query_words("error: build failed due to dependency");
        let query_words: Vec<&str> = query_words_owned.iter().map(|s| s.as_str()).collect();
        let fm = hc(1, NIX_BUILD_ERROR, 1000, 1.0, &query_words, false);

        let densest_idx =
            find_densest_highlight(&fm.highlight_ranges, SNIPPET_CONTEXT_CHARS as u64).unwrap();
        let densest_start = fm.highlight_ranges[densest_idx].start as usize;

        let final_block =
            "error: Cannot build '/nix/store/djv08y006z7jk69j2q9fq5f1ch195i4s-home-manager.drv'.";
        let final_block_byte_pos = NIX_BUILD_ERROR.rfind(final_block).unwrap();
        let final_block_char_pos = NIX_BUILD_ERROR[..final_block_byte_pos].chars().count();

        assert!(
            densest_start >= final_block_char_pos,
            "Densest highlight at char {} should be in final error block (char {}+). \
             Points to: {:?}",
            densest_start,
            final_block_char_pos,
            NIX_BUILD_ERROR
                .chars()
                .skip(densest_start)
                .take(60)
                .collect::<String>()
        );
    }

    #[test]
    fn test_snippet_centers_on_exact_query_match_not_scattered_repeats() {
        let query_words_owned = build_query_words("error: build failed due to dependency");
        let query_words: Vec<&str> = query_words_owned.iter().map(|s| s.as_str()).collect();
        let fm = hc(1, NIX_BUILD_ERROR, 1000, 1.0, &query_words, false);

        let (snippet, _, _) = generate_snippet(
            NIX_BUILD_ERROR,
            &fm.highlight_ranges,
            SNIPPET_CONTEXT_CHARS * 2,
        );

        assert!(
            snippet.contains("Build failed due to failed dependency"),
            "Snippet should center on the near-exact match line, got: {}",
            snippet
        );
    }

    #[test]
    fn test_prefix_highlight_does_not_outrank_earlier_exact_match() {
        let content = "func top level\n\nlet x = 1;\n\nfunction later match";
        let highlights = compute_scalar_highlights(content, "func");

        assert!(highlights.len() >= 3);

        let first = &highlights[0];
        let second = &highlights[1];

        assert_eq!(first.start, 0);
        assert_eq!(first.end, 4);
        assert_eq!(first.kind, HighlightKind::Exact);

        let second_highlighted: String = content
            .chars()
            .skip(second.start as usize)
            .take((second.end - second.start) as usize)
            .collect();
        assert_eq!(second.kind, HighlightKind::Prefix);
        assert_eq!(second_highlighted, "func");

        let third = &highlights[2];
        let third_highlighted: String = content
            .chars()
            .skip(third.start as usize)
            .take((third.end - third.start) as usize)
            .collect();
        assert_eq!(third.kind, HighlightKind::PrefixTail);
        assert_eq!(third_highlighted, "tion");

        let preview = create_preview_decoration(
            content,
            &HighlightAnalysis {
                initial_scroll_highlight_index: Some(0),
                highlights: highlights.clone(),
            },
        );
        assert_eq!(preview.initial_scroll_highlight_index, Some(0));

        let row = compute_matched_excerpt(content, "func", ListPresentationProfile::CompactRow);
        assert!(row.text.contains("func top level"));
    }

    #[test]
    fn test_preview_decoration_limits_highlights_around_anchor() {
        let content = "x".repeat(3000);
        let highlights: Vec<HighlightRange> = (0..200)
            .map(|index| HighlightRange {
                start: (index * 10) as u64,
                end: (index * 10 + 1) as u64,
                kind: HighlightKind::Exact,
            })
            .collect();
        let analysis = HighlightAnalysis {
            highlights,
            initial_scroll_highlight_index: Some(100),
        };

        let preview = create_preview_decoration(&content, &analysis);

        assert!(preview.highlights.len() <= PREVIEW_MAX_HIGHLIGHTS);
        let anchor_index = preview.initial_scroll_highlight_index.unwrap() as usize;
        assert!(anchor_index < preview.highlights.len());
        assert_eq!(preview.highlights[anchor_index].utf16_start, 1000);
    }

    #[test]
    fn test_preview_decoration_with_char_offset_limits_and_shifts_anchor() {
        let content = "x".repeat(4000);
        let highlights: Vec<HighlightRange> = (0..150)
            .map(|index| HighlightRange {
                start: (index * 8) as u64,
                end: (index * 8 + 2) as u64,
                kind: HighlightKind::Exact,
            })
            .collect();
        let analysis = HighlightAnalysis {
            highlights,
            initial_scroll_highlight_index: Some(75),
        };

        let preview = create_preview_decoration_with_char_offset(&content, &analysis, 500);

        assert!(preview.highlights.len() <= PREVIEW_MAX_HIGHLIGHTS);
        let anchor_index = preview.initial_scroll_highlight_index.unwrap() as usize;
        assert!(anchor_index < preview.highlights.len());
        assert_eq!(preview.highlights[anchor_index].utf16_start, 1100);
    }

    // ── HighlightKind verification tests ──────────────────────────

    #[test]
    fn test_highlight_match_kind_exact() {
        let fm = hc(1, "hello world", 1000, 1.0, &["hello"], false);
        assert_eq!(fm.highlight_ranges.len(), 1);
        assert_eq!(fm.highlight_ranges[0].kind, HighlightKind::Exact);
    }

    #[test]
    fn test_highlight_match_kind_prefix() {
        let fm = hc(1, "Run testing suite now", 1000, 1.0, &["test"], true);
        assert_eq!(fm.highlight_ranges.len(), 2);
        assert_eq!(fm.highlight_ranges[0].kind, HighlightKind::Prefix);
        assert_eq!(fm.highlight_ranges[1].kind, HighlightKind::PrefixTail);
    }

    #[test]
    fn test_highlight_match_kind_subword_prefix() {
        let fm = hc(1, "responseCode", 1000, 1.0, &["code"], false);
        assert_eq!(fm.highlight_ranges.len(), 1);
        let highlight = &fm.highlight_ranges[0];
        assert_eq!(highlight.kind, HighlightKind::SubwordPrefix);
        assert_eq!((highlight.start, highlight.end), (8, 12));
    }

    #[test]
    fn test_highlight_match_kind_substring() {
        let fm = hc(1, "import data", 1000, 1.0, &["port"], false);
        assert_eq!(fm.highlight_ranges.len(), 1);
        let highlight = &fm.highlight_ranges[0];
        assert_eq!(highlight.kind, HighlightKind::Substring);
        assert_eq!((highlight.start, highlight.end), (2, 6));
    }

    #[test]
    fn test_highlight_infix_numeric_match_marks_only_literal_span() {
        let fm = hc(1, "911396997", 1000, 1.0, &["997"], false);
        assert_eq!(fm.highlight_ranges.len(), 1);
        let highlight = &fm.highlight_ranges[0];
        assert_eq!(highlight.kind, HighlightKind::Substring);
        assert_eq!((highlight.start, highlight.end), (6, 9));
    }

    #[test]
    fn test_highlight_match_kind_fuzzy() {
        // "riversde" matches "riverside" via fuzzy edit distance
        let fm = hc(
            1,
            "Visit Riverside Park today",
            1000,
            1.0,
            &["riversde"],
            false,
        );
        assert_eq!(fm.highlight_ranges.len(), 1);
        assert_eq!(fm.highlight_ranges[0].kind, HighlightKind::Fuzzy);
    }

    #[test]
    fn test_highlight_match_kind_subsequence() {
        // "impt" matches "import" via subsequence (len diff 2 exceeds max_dist 1)
        let fm = hc(1, "import data", 1000, 1.0, &["impt"], false);
        assert_eq!(fm.highlight_ranges.len(), 1);
        assert_eq!(fm.highlight_ranges[0].kind, HighlightKind::Subsequence);
    }
}
