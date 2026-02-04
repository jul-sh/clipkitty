import Testing
import Foundation

/// Tests for the 15/85 snippet windowing logic implemented in ContentView.swift
/// This ensures matches are correctly positioned and visible in the truncated UI view.
@Suite("Snippet Window Tests")
struct SnippetWindowTests {

    private let maxDisplayChars = 200

    /// Mirror of the logic in ContentView.swift
    private func calculateWindow(
        sourceText: String,
        matchStart: Int,
        matchEnd: Int,
        lineNumber: Int
    ) -> (start: Int, end: Int, prefix: String) {
        let basePrefix = lineNumber > 1 ? "L\(lineNumber): …" : ""
        let estimatedPrefixLen = basePrefix.count + (lineNumber == 1 ? 1 : 0)
        let availableChars = maxDisplayChars - estimatedPrefixLen

        if sourceText.count <= availableChars && lineNumber == 1 {
            return (0, sourceText.count, "")
        }

        // Match-centered logic with 15/85 split
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

        // Final prefix
        var finalPrefix = basePrefix
        if lineNumber == 1 && start > 0 {
            finalPrefix = "…"
        }

        // Recalculate end with exact prefix length
        let totalAllowed = maxDisplayChars - finalPrefix.count
        let currentLen = end - start
        if currentLen > totalAllowed {
            end = start + totalAllowed
        }

        return (start, end, finalPrefix)
    }

    @Test("Match in middle is centered with 15/85 split")
    func testMatchCentering() {
        // Create a long text: 100 'a's, "MATCH", 400 'b's
        let prefix = String(repeating: "a", count: 100)
        let suffix = String(repeating: "b", count: 400)
        let text = prefix + "MATCH" + suffix

        let matchStart = 100
        let matchEnd = 105

        let (start, end, prefixStr) = calculateWindow(sourceText: text, matchStart: matchStart, matchEnd: matchEnd, lineNumber: 1)

        #expect(prefixStr == "…")
        #expect(start > 0)
        #expect(start < matchStart)
        #expect(end > matchEnd)

        // Verify 15/85 split roughly
        let charsBeforeMatch = matchStart - start
        let charsAfterMatch = end - matchEnd
        let ratio = Double(charsBeforeMatch) / Double(charsBeforeMatch + charsAfterMatch)

        // Should be around 0.15 (allowing some margin for rounding and prefix adjustment)
        #expect(ratio > 0.05 && ratio < 0.20)
    }

    @Test("Match near start shows from beginning")
    func testMatchNearStart() {
        let text = "Small prefix MATCH " + String(repeating: "x", count: 500)
        let matchStart = 13
        let matchEnd = 18

        let (start, _, prefixStr) = calculateWindow(sourceText: text, matchStart: matchStart, matchEnd: matchEnd, lineNumber: 1)

        #expect(start == 0)
        #expect(prefixStr == "")
    }

    @Test("Match near end shows until end")
    func testMatchNearEnd() {
        let text = String(repeating: "x", count: 500) + " MATCH tail"
        let matchStart = 501
        let matchEnd = 506

        let (_, end, prefixStr) = calculateWindow(sourceText: text, matchStart: matchStart, matchEnd: matchEnd, lineNumber: 1)

        #expect(end == text.count)
        #expect(prefixStr == "…")
    }

    @Test("Line number prefix is preserved")
    func testLineNumberPrefix() {
        let text = String(repeating: "x", count: 500) + "MATCH"
        let matchStart = 500
        let matchEnd = 505

        let (_, _, prefixStr) = calculateWindow(sourceText: text, matchStart: matchStart, matchEnd: matchEnd, lineNumber: 42)

        #expect(prefixStr == "L42: …")
    }
}
