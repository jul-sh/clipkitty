import ClipKittyRust
import ClipKittyShared

extension DisplayRow {
    /// The excerpt text and search-highlight ranges the feed renders for this
    /// row, collapsing the presentation state machine down to what is
    /// drawable right now. Shared between `CardView` (rendering) and
    /// `CardRowChunk` (width estimation for row packing).
    var displayExcerpt: (text: String, highlights: [Utf16HighlightRange]) {
        switch presentation {
        case let .baseline(excerpt):
            return (excerpt.text, [])
        case let .matched(excerpt):
            return (excerpt.text, excerpt.highlights)
        case let .deferred(_, placeholder):
            switch placeholder {
            case let .baseline(excerpt), let .provisional(excerpt):
                return (excerpt.text, [])
            case let .compatibleCached(_, excerpt):
                return (excerpt.text, excerpt.highlights)
            }
        case let .unavailable(fallback, _):
            return (fallback.text, [])
        }
    }
}
