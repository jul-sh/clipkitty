import Testing
import Foundation

/// Tests for snippet truncation and positioning logic
///
/// Documents the expected behavior for how search result snippets are
/// constructed, truncated, and displayed. This logic should live in Swift
/// since Swift owns the display width and determines final truncation.
///
/// Key behaviors:
/// - Max display length: 200 characters (excluding ellipsis)
/// - Leading ellipsis "…" when snippet doesn't start at beginning
/// - Line number prefix "L{n}: " for matches not on line 1
/// - Whitespace normalization (collapse spaces, convert newlines/tabs to spaces)
/// - Context: ~10 chars before match, rest of available space after
@Suite("Snippet Truncation Tests")
struct SnippetTruncationTests {

    // MARK: - Helper Functions (Mirror Swift Logic)

    /// Flatten text: replace newlines/tabs with spaces, collapse consecutive spaces
    private func flatten(_ text: String, maxChars: Int) -> String {
        var result = String()
        result.reserveCapacity(min(maxChars + 1, text.count))
        var lastWasSpace = false
        var count = 0
        for char in text {
            guard count < maxChars else { break }
            var c = char
            if c == "\n" || c == "\t" || c == "\r" { c = " " }
            if c == " " {
                if lastWasSpace { continue }
                lastWasSpace = true
            } else {
                lastWasSpace = false
            }
            result.append(c)
            count += 1
        }
        return result
    }

    /// Count line number (1-indexed) at a given character offset
    private func lineNumber(at offset: Int, in text: String) -> Int {
        var line = 1
        var idx = text.startIndex
        let targetIdx = text.index(text.startIndex, offsetBy: min(offset, text.count))
        while idx < targetIdx {
            if text[idx] == "\n" { line += 1 }
            idx = text.index(after: idx)
        }
        return line
    }

    /// Display text for browse mode (no search query)
    /// Truncates to 200 chars with trailing ellipsis if needed
    private func displaySnippet(_ text: String) -> String {
        let maxChars = 200
        var result = String()
        result.reserveCapacity(maxChars + 1)

        var index = text.startIndex
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }

        var count = 0
        var lastWasSpace = false
        var hasMore = false

        while index < text.endIndex, count < maxChars {
            var character = text[index]
            if character == "\n" || character == "\t" || character == "\r" {
                character = " "
            }
            if character == " " {
                if lastWasSpace {
                    index = text.index(after: index)
                    continue
                }
                lastWasSpace = true
            } else {
                lastWasSpace = false
            }

            result.append(character)
            count += 1
            index = text.index(after: index)
        }

        if index < text.endIndex {
            hasMore = true
        }

        return hasMore ? result + "…" : result
    }

    /// Generate preview text for search mode
    /// - Parameters:
    ///   - fullText: The complete text content
    ///   - query: The search query
    /// - Returns: The formatted preview snippet with appropriate prefix/truncation
    private func previewText(fullText: String, query: String) -> String {
        let displaySnippetValue = displaySnippet(fullText)
        guard !query.isEmpty else { return displaySnippetValue }

        // Try exact match first
        guard let range = fullText.range(of: query, options: .caseInsensitive) else {
            return displaySnippetValue
        }

        let matchStart = fullText.distance(from: fullText.startIndex, to: range.lowerBound)
        let line = lineNumber(at: matchStart, in: fullText)

        // If match is early in the text and on line 1, just return displaySnippet
        if matchStart < 20 && line == 1 {
            return displaySnippetValue
        }

        // Build prefix: show line number if not on first line
        let prefix = line > 1 ? "L\(line): …" : "…"

        // Extract context around the match and flatten it
        let contextStart = max(0, matchStart - 10)
        let contextEnd = min(fullText.count, matchStart + 200)
        let startIndex = fullText.index(fullText.startIndex, offsetBy: contextStart)
        let endIndex = fullText.index(fullText.startIndex, offsetBy: contextEnd)
        let context = String(fullText[startIndex..<endIndex])
        return prefix + flatten(context, maxChars: 200)
    }

    // MARK: - Browse Mode Tests (No Search Query)

    @Test("Short text has no ellipsis")
    func browseShortText() {
        let text = "Hello World"
        let result = displaySnippet(text)
        #expect(result == "Hello World")
        #expect(!result.hasSuffix("…"))
    }

    @Test("Exactly 200 chars has no ellipsis")
    func browseExactly200Chars() {
        let text = String(repeating: "a", count: 200)
        let result = displaySnippet(text)
        #expect(result.count == 200)
        #expect(!result.hasSuffix("…"))
    }

    @Test("201 chars gets truncated with ellipsis")
    func browse201Chars() {
        let text = String(repeating: "a", count: 201)
        let result = displaySnippet(text)
        #expect(result.count == 201) // 200 chars + ellipsis
        #expect(result.hasSuffix("…"))
    }

    @Test("Long text gets truncated with trailing ellipsis")
    func browseLongText() {
        let text = String(repeating: "a", count: 500)
        let result = displaySnippet(text)
        #expect(result.hasSuffix("…"))
        #expect(result.count == 201)
    }

    @Test("Leading whitespace is skipped")
    func browseLeadingWhitespace() {
        let text = "   Hello World"
        let result = displaySnippet(text)
        #expect(result == "Hello World")
        #expect(!result.hasPrefix(" "))
    }

    @Test("Consecutive whitespace is collapsed")
    func browseConsecutiveWhitespace() {
        let text = "Hello    World"
        let result = displaySnippet(text)
        #expect(result == "Hello World")
    }

    @Test("Newlines are converted to spaces")
    func browseNewlines() {
        let text = "Hello\n\nWorld"
        let result = displaySnippet(text)
        #expect(result == "Hello World")
    }

    @Test("Tabs are converted to spaces")
    func browseTabs() {
        let text = "Hello\t\tWorld"
        let result = displaySnippet(text)
        #expect(result == "Hello World")
    }

    // MARK: - Search Mode Tests - Match at Start

    @Test("Match at very start returns displaySnippet")
    func searchMatchAtStart() {
        let text = "Hello World this is some text"
        let result = previewText(fullText: text, query: "Hello")
        // Match is at position 0, line 1, so returns displaySnippet
        #expect(result == "Hello World this is some text")
        #expect(!result.hasPrefix("…"))
    }

    @Test("Match early (< 20 chars) on line 1 returns displaySnippet")
    func searchMatchEarly() {
        let text = "abc Hello World xyz"
        let result = previewText(fullText: text, query: "Hello")
        // Match starts at position 4, which is < 20
        #expect(result == "abc Hello World xyz")
        #expect(!result.hasPrefix("…"))
    }

    // MARK: - Search Mode Tests - Match in Middle

    @Test("Match past 20 chars on line 1 has leading ellipsis")
    func searchMatchPast20Chars() {
        let prefix = String(repeating: "x", count: 25)
        let text = "\(prefix)MATCH this is the rest"
        let result = previewText(fullText: text, query: "MATCH")
        // Match starts at position 25, so we need ellipsis
        #expect(result.hasPrefix("…"))
        #expect(result.contains("MATCH"))
        // Should NOT have line number since it's still on line 1
        #expect(!result.hasPrefix("L"))
    }

    @Test("Match on line 2 has line number prefix")
    func searchMatchOnLine2() {
        let text = "First line\nSecond line with MATCH here"
        let result = previewText(fullText: text, query: "MATCH")
        // Match is on line 2
        #expect(result.hasPrefix("L2: …"))
        #expect(result.contains("MATCH"))
    }

    @Test("Match on line 5 has correct line number")
    func searchMatchOnLine5() {
        let text = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5 has MATCH"
        let result = previewText(fullText: text, query: "MATCH")
        #expect(result.hasPrefix("L5: …"))
    }

    // MARK: - Search Mode Tests - Context Extraction

    @Test("Context includes ~10 chars before match")
    func searchContextBefore() {
        let prefix = String(repeating: "a", count: 50)
        let text = "\(prefix)MATCH rest"
        let result = previewText(fullText: text, query: "MATCH")
        // Context starts 10 chars before match (at position 40)
        // So we should see some 'a' chars before MATCH
        #expect(result.hasPrefix("…"))
        #expect(result.contains("aaaaaMATCH") || result.contains("aaaaMATCH"))
    }

    @Test("Context is flattened (whitespace normalized)")
    func searchContextFlattened() {
        let text = String(repeating: "x", count: 30) + "before\n\n\nMATCH\t\tafter"
        let result = previewText(fullText: text, query: "MATCH")
        // Newlines and tabs should become single spaces
        #expect(!result.contains("\n"))
        #expect(!result.contains("\t"))
        #expect(result.contains("before MATCH after"))
    }

    // MARK: - Search Mode Tests - Long Content

    @Test("Long content after match is truncated")
    func searchLongContentTruncated() {
        let prefix = String(repeating: "x", count: 30)
        let suffix = String(repeating: "z", count: 500)
        let text = "\(prefix)MATCH\(suffix)"
        let result = previewText(fullText: text, query: "MATCH")
        // Result should be bounded (prefix + context up to 200)
        // Leading ellipsis (1) + content (200) = 201 max
        #expect(result.count <= 210) // Some flexibility for prefix
    }

    // MARK: - Search Mode Tests - Edge Cases

    @Test("Empty query returns displaySnippet")
    func searchEmptyQuery() {
        let text = "Hello World"
        let result = previewText(fullText: text, query: "")
        #expect(result == "Hello World")
    }

    @Test("Non-matching query returns displaySnippet")
    func searchNoMatch() {
        let text = "Hello World"
        let result = previewText(fullText: text, query: "xyz")
        #expect(result == "Hello World")
    }

    @Test("Case insensitive matching")
    func searchCaseInsensitive() {
        let text = "Hello WORLD here"
        let result = previewText(fullText: text, query: "world")
        // Should match despite different case
        #expect(result == "Hello WORLD here")
    }

    // MARK: - Highlight Position Tests

    /// When Rust provides highlights, Swift must adjust them if it adds a prefix
    @Test("Highlight positions account for line prefix")
    func highlightWithLinePrefix() {
        // Given: Rust says highlight is at position 0-5 in the snippet "MATCH text"
        let rustHighlightStart: UInt64 = 0
        let rustHighlightEnd: UInt64 = 5
        let lineNumber = 3

        // When: Swift adds "L3: " prefix
        let prefix = "L\(lineNumber): …"
        let offset = UInt64(prefix.count)

        // Then: Highlight positions must shift by prefix length
        let adjustedStart = rustHighlightStart + offset
        let adjustedEnd = rustHighlightEnd + offset

        let fullText = "\(prefix)MATCH text"
        let highlightedPortion = String(fullText.dropFirst(Int(adjustedStart)).prefix(Int(adjustedEnd - adjustedStart)))
        #expect(highlightedPortion == "MATCH")
    }

    @Test("Highlight positions with leading ellipsis only")
    func highlightWithEllipsisOnly() {
        // Given: Match not on line 1 but needs ellipsis prefix
        let rustHighlightStart: UInt64 = 5
        let rustHighlightEnd: UInt64 = 10

        // When: Swift adds just "…" prefix (line 1 but position > 20)
        let prefix = "…"
        let offset = UInt64(prefix.count)

        // Then: Highlight shifts by 1
        let adjustedStart = rustHighlightStart + offset
        let adjustedEnd = rustHighlightEnd + offset

        #expect(adjustedStart == 6)
        #expect(adjustedEnd == 11)
    }
}
