import Testing
import Foundation

/// Tests for the snippet windowing logic implemented in ContentView.swift
/// Rust now handles leading ellipsis; Swift just does windowing.
@Suite("Snippet Window Tests")
struct SnippetWindowTests {

    // Match actual visible row width (~280px at font size 15)
    private let maxDisplayChars = 50

    /// Mirror of the simplified logic in ContentView.swift
    /// No more prefix handling - Rust adds "…" when truncated
    private func calculateWindow(
        sourceText: String,
        matchStart: Int,
        matchEnd: Int
    ) -> (start: Int, end: Int) {
        // If no match, just take from start
        guard matchStart >= 0 else {
            let limit = min(sourceText.count, maxDisplayChars)
            return (0, limit)
        }

        let availableChars = maxDisplayChars

        // Position window with 15% context before match, 85% after
        let contextBefore = Int(Double(availableChars) * 0.15)
        var start = matchStart - contextBefore
        var end = start + availableChars

        // Clamp to bounds
        if start < 0 {
            start = 0
            end = min(sourceText.count, availableChars)
        } else if end > sourceText.count {
            end = sourceText.count
            start = max(0, end - availableChars)
        }

        // Ensure match end is visible
        if matchEnd > end {
            end = min(sourceText.count, matchEnd + 10)
            start = max(0, end - availableChars)
        }

        return (start, end)
    }

    @Test("Match in middle is centered with 15/85 split")
    func testMatchCentering() {
        // Create a long text: 30 'a's, "MATCH", 100 'b's
        let prefix = String(repeating: "a", count: 30)
        let suffix = String(repeating: "b", count: 100)
        let text = prefix + "MATCH" + suffix

        let matchStart = 30
        let matchEnd = 35

        let (start, end) = calculateWindow(sourceText: text, matchStart: matchStart, matchEnd: matchEnd)

        #expect(start > 0)
        #expect(start < matchStart)
        #expect(end > matchEnd)

        // Verify match is visible
        #expect(matchStart >= start && matchEnd <= end, "Match must be within window")
    }

    @Test("Match near start keeps match visible")
    func testMatchNearStart() {
        let text = "Small prefix MATCH " + String(repeating: "x", count: 100)
        let matchStart = 13
        let matchEnd = 18

        let (start, end) = calculateWindow(sourceText: text, matchStart: matchStart, matchEnd: matchEnd)

        // Match should be visible within the window
        #expect(matchStart >= start && matchEnd <= end, "Match must be within window")
    }

    @Test("Match near end keeps match visible")
    func testMatchNearEnd() {
        let text = String(repeating: "x", count: 100) + " MATCH tail"
        let matchStart = 101
        let matchEnd = 106

        let (start, end) = calculateWindow(sourceText: text, matchStart: matchStart, matchEnd: matchEnd)

        // Match should be visible
        #expect(matchStart >= start && matchEnd <= end, "Match must be within window")
    }

    // MARK: - Rust→Swift Contract Documentation

    /// Documents the Rust ellipsis prefixing behavior.
    /// When Rust truncates from start, it prefixes "…" and adjusts highlight indices.
    @Test("Rust ellipsis prefix adjusts highlight indices")
    func testRustEllipsisPrefixContract() {
        // Simulating what Rust does:
        // If Rust truncates from start (snippet_start_char > 0), it:
        // 1. Prefixes "…" to the snippet
        // 2. Adds 1 to highlight start/end indices

        let rustSnippetWithEllipsis = "…def handler(event, context): return {'message': 'Hello'}"
        // "Hello" is at the end: snippet ends with 'Hello'}"
        // String length is 58 chars, "Hello" is at positions 51-56

        // Find where "Hello" actually is
        guard let helloRange = rustSnippetWithEllipsis.range(of: "Hello") else {
            Issue.record("Could not find 'Hello' in snippet")
            return
        }
        let adjustedMatchStart = rustSnippetWithEllipsis.distance(from: rustSnippetWithEllipsis.startIndex, to: helloRange.lowerBound)
        let adjustedMatchEnd = rustSnippetWithEllipsis.distance(from: rustSnippetWithEllipsis.startIndex, to: helloRange.upperBound)

        // Verify extraction works
        let idx1 = rustSnippetWithEllipsis.index(rustSnippetWithEllipsis.startIndex, offsetBy: adjustedMatchStart)
        let idx2 = rustSnippetWithEllipsis.index(rustSnippetWithEllipsis.startIndex, offsetBy: adjustedMatchEnd)
        let matchText = String(rustSnippetWithEllipsis[idx1..<idx2])

        #expect(matchText == "Hello", "Highlight should correctly identify 'Hello' at adjusted position")
        #expect(rustSnippetWithEllipsis.hasPrefix("…"), "Rust should prefix ellipsis when truncated")
    }

    @Test("Swift windowing on Rust-truncated snippet")
    func testSwiftWindowingOnTruncatedSnippet() {
        // Rust already truncated and added "…" prefix
        let rustSnippet = "…def handler(event, context): return {'message': 'Hello'}"
        let matchStart = 54  // "Hello" position
        let matchEnd = 59

        let (start, end) = calculateWindow(sourceText: rustSnippet, matchStart: matchStart, matchEnd: matchEnd)

        // Extract windowed content
        let idx1 = rustSnippet.index(rustSnippet.startIndex, offsetBy: start)
        let idx2 = rustSnippet.index(rustSnippet.startIndex, offsetBy: min(end, rustSnippet.count))
        let displayText = String(rustSnippet[idx1..<idx2])

        // CRITICAL: Match must be visible!
        #expect(displayText.contains("Hello"), "Display MUST include the match 'Hello'")
    }
}
