import Foundation

/// High-performance fuzzy matching algorithm inspired by fzf
/// Scores matches based on:
/// - Consecutive character matches (bonus)
/// - Matches at word boundaries (bonus)
/// - Matches at start of string (bonus)
/// - Gaps between matches (penalty)
struct FuzzyMatch {

    /// Match result with score and match positions
    struct Result {
        let score: Int
        let positions: [Int]  // Indices of matched characters in the target

        static let noMatch = Result(score: 0, positions: [])

        var isMatch: Bool { !positions.isEmpty }
    }

    // Scoring constants (tuned similar to fzf)
    private static let scoreMatch = 16
    private static let scoreGapStart = -3
    private static let scoreGapExtension = -1
    private static let bonusConsecutive = 8
    private static let bonusBoundary = 8
    private static let bonusFirstChar = 8
    private static let bonusCamelCase = 7
    private static let bonusAfterSlash = 9
    private static let bonusAfterSpace = 8

    /// Performs fuzzy match of pattern against text
    /// Returns nil if no match, otherwise returns score and positions
    static func match(pattern: String, in text: String) -> Result? {
        guard !pattern.isEmpty else { return Result(score: 0, positions: []) }
        guard !text.isEmpty else { return nil }

        let patternChars = Array(pattern.lowercased())
        let textChars = Array(text)
        let textLower = Array(text.lowercased())

        let n = textChars.count
        let m = patternChars.count

        guard m <= n else { return nil }

        // Quick check: does text contain all pattern chars in order?
        var patternIdx = 0
        for char in textLower {
            if char == patternChars[patternIdx] {
                patternIdx += 1
                if patternIdx == m { break }
            }
        }
        guard patternIdx == m else { return nil }

        // Use dynamic programming to find best match
        // score[i][j] = best score matching pattern[0..i] to text[0..j]
        // We use two rows to save memory

        var positions = [Int](repeating: -1, count: m)
        var score = 0

        // Greedy forward pass to find initial match positions
        patternIdx = 0
        for (textIdx, char) in textLower.enumerated() {
            if patternIdx < m && char == patternChars[patternIdx] {
                positions[patternIdx] = textIdx
                patternIdx += 1
            }
        }

        // Calculate score based on positions
        score = calculateScore(positions: positions, textChars: textChars, textLower: textLower, patternChars: patternChars)

        // Try to optimize by finding better positions (simple backtracking)
        let optimized = optimizePositions(
            positions: positions,
            textChars: textChars,
            textLower: textLower,
            patternChars: patternChars,
            currentScore: score
        )

        return Result(score: optimized.score, positions: optimized.positions)
    }

    private static func calculateScore(
        positions: [Int],
        textChars: [Character],
        textLower: [Character],
        patternChars: [Character]
    ) -> Int {
        guard !positions.isEmpty else { return 0 }

        var score = 0
        var prevPos = -1

        for (_, pos) in positions.enumerated() {
            // Base match score
            score += scoreMatch

            // First character bonus
            if pos == 0 {
                score += bonusFirstChar
            }

            // Consecutive match bonus
            if prevPos >= 0 && pos == prevPos + 1 {
                score += bonusConsecutive
            } else if prevPos >= 0 {
                // Gap penalty
                let gap = pos - prevPos - 1
                score += scoreGapStart + (gap - 1) * scoreGapExtension
            }

            // Boundary bonus
            if pos > 0 {
                let prevChar = textChars[pos - 1]
                let currChar = textChars[pos]

                if prevChar == "/" || prevChar == "\\" {
                    score += bonusAfterSlash
                } else if prevChar == " " || prevChar == "_" || prevChar == "-" {
                    score += bonusAfterSpace
                } else if prevChar.isLowercase && currChar.isUppercase {
                    score += bonusCamelCase
                } else if !prevChar.isLetter && currChar.isLetter {
                    score += bonusBoundary
                }
            }

            prevPos = pos
        }

        return score
    }

    private static func optimizePositions(
        positions: [Int],
        textChars: [Character],
        textLower: [Character],
        patternChars: [Character],
        currentScore: Int
    ) -> (score: Int, positions: [Int]) {
        var bestScore = currentScore
        var bestPositions = positions

        // Try to find better positions by looking for alternative matches
        // Start from the end and try to find consecutive matches
        for i in (0..<positions.count).reversed() {
            let targetChar = patternChars[i]
            let currentPos = positions[i]
            let minPos = i == 0 ? 0 : bestPositions[i - 1] + 1

            // Look for earlier occurrences that might score better
            for newPos in minPos..<currentPos {
                if textLower[newPos] == targetChar {
                    var testPositions = bestPositions
                    testPositions[i] = newPos

                    // Ensure subsequent positions are still valid
                    var valid = true
                    var searchFrom = newPos + 1
                    for j in (i + 1)..<positions.count {
                        let found = findNext(char: patternChars[j], in: textLower, from: searchFrom)
                        if let foundPos = found {
                            testPositions[j] = foundPos
                            searchFrom = foundPos + 1
                        } else {
                            valid = false
                            break
                        }
                    }

                    if valid {
                        let newScore = calculateScore(
                            positions: testPositions,
                            textChars: textChars,
                            textLower: textLower,
                            patternChars: patternChars
                        )
                        if newScore > bestScore {
                            bestScore = newScore
                            bestPositions = testPositions
                        }
                    }
                }
            }
        }

        return (bestScore, bestPositions)
    }

    private static func findNext(char: Character, in text: [Character], from: Int) -> Int? {
        for i in from..<text.count {
            if text[i] == char {
                return i
            }
        }
        return nil
    }
}

/// Extension for fuzzy filtering and sorting collections
extension Array where Element == ClipboardItem {

    /// Filter and sort items by fuzzy match score
    func fuzzyMatch(query: String) -> [Element] {
        guard !query.isEmpty else { return self }

        let results: [(item: Element, score: Int)] = self.compactMap { item in
            if let result = FuzzyMatch.match(pattern: query, in: item.content) {
                return (item, result.score)
            }
            return nil
        }

        // Sort by score descending
        return results
            .sorted { $0.score > $1.score }
            .map { $0.item }
    }
}

/// Extension for creating highlighted attributed strings
extension String {

    /// Create an AttributedString with fuzzy match positions highlighted
    func fuzzyHighlighted(query: String, highlightColor: Color = .yellow.opacity(0.4)) -> AttributedString {
        var result = AttributedString(self)

        guard !query.isEmpty,
              let match = FuzzyMatch.match(pattern: query, in: self) else {
            return result
        }

        let stringIndex = self.startIndex
        for pos in match.positions {
            let charIndex = self.index(stringIndex, offsetBy: pos)
            let nextIndex = self.index(after: charIndex)
            let range = charIndex..<nextIndex

            if let attrRange = Range(range, in: result) {
                result[attrRange].backgroundColor = highlightColor
            }
        }

        return result
    }
}

import SwiftUI
