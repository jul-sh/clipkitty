import ClipKittyRust
import ClipKittyShared
import SwiftUI

/// A left-to-right feed row of up to `JustifiedCardRow.maxCardsPerRow` clips,
/// used on wide iPad layouts. Packing happens in two stages:
///
/// 1. `CardRowChunk.pack` groups the flat feed into rows using cheap
///    content-based width estimates. Estimation (rather than live
///    measurement) keeps the feed lazy: the whole history can be chunked
///    without building a card view per item.
/// 2. `JustifiedCardRow` lays out each on-screen row from the cards' real
///    measured ideal widths, stretching them proportionally so every row is
///    filled edge to edge while naturally short clips stay narrow.
struct CardRowChunk: Identifiable {
    let id: String
    let rows: [DisplayRow]

    init(rows: [DisplayRow]) {
        self.rows = rows
        id = rows.map(\.id).joined(separator: "|")
    }

    /// How far the summed width estimates may exceed the row width and still
    /// pack together. Estimates are ideal (unwrapped) widths; text absorbs a
    /// modest squeeze by wrapping a line, so requiring a strict fit leaves
    /// rows visibly underfilled.
    private static let packingSlack: CGFloat = 1.15

    /// Greedily groups `rows` into feed rows: a clip joins the current row
    /// while the row has fewer than `maxCardsPerRow` clips and the estimated
    /// widths still fit `rowWidth` (with `packingSlack` squeeze); otherwise
    /// it starts a new row.
    static func pack(_ rows: [DisplayRow], rowWidth: CGFloat) -> [CardRowChunk] {
        guard rowWidth > 0 else {
            return rows.map { CardRowChunk(rows: [$0]) }
        }

        var chunks: [CardRowChunk] = []
        var pending: [DisplayRow] = []
        var pendingWidth: CGFloat = 0

        for row in rows {
            let estimated = estimatedWidth(for: row)
            let joinsCurrentRow = !pending.isEmpty
                && pending.count < JustifiedCardRow.maxCardsPerRow
                && pendingWidth + JustifiedCardRow.spacing + estimated <= rowWidth * Self.packingSlack

            if joinsCurrentRow {
                pending.append(row)
                pendingWidth += JustifiedCardRow.spacing + estimated
            } else {
                if !pending.isEmpty {
                    chunks.append(CardRowChunk(rows: pending))
                }
                pending = [row]
                pendingWidth = estimated
            }
        }
        if !pending.isEmpty {
            chunks.append(CardRowChunk(rows: pending))
        }
        return chunks
    }

    /// Rough natural width of a card in points, from metadata alone. Only
    /// relative accuracy matters: `JustifiedCardRow` re-measures the real
    /// views when distributing the row's width.
    private static func estimatedWidth(for row: DisplayRow) -> CGFloat {
        switch row.metadata.icon {
        case .colorSwatch:
            return 240
        case .thumbnail:
            // The card image is height-capped (see CardView.thumbnailPreview),
            // so image cards no longer want the full-bleed widths they did
            // uncapped.
            return 360
        case let .symbol(iconType):
            switch iconType {
            case .link:
                return 340
            case .image, .file:
                return 340
            case .color:
                return 240
            case .text:
                // The longest rendered line drives the natural width: ~8pt
                // per character at the 15pt preview size, plus card padding.
                // Cards clamp text to 8 lines, so later lines can't widen it.
                let longestLine = row.displayExcerpt.text
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .prefix(8)
                    .map(\.count)
                    .max() ?? 0
                return min(max(CGFloat(longestLine) * 8 + 28, 220), 640)
            }
        }
    }
}

/// Lays out one feed row's cards left to right, top-aligned, splitting the
/// full row width between them so the row is always filled edge to edge.
struct JustifiedCardRow: Layout {
    /// Feed width at which the iPad feed switches from the single-column
    /// list to packed multi-clip rows (full screen or a large window).
    static let multiColumnMinimumWidth: CGFloat = 700
    static let maxCardsPerRow = 3
    static let spacing: CGFloat = 12
    /// Readability floor: no card is squeezed narrower than this.
    static let minCardWidth: CGFloat = 200

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width
            ?? subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.unspecified).width }
            + Self.spacing * CGFloat(subviews.count - 1)
        let height = zip(subviews, justifiedWidths(totalWidth: width, subviews: subviews))
            .map { subview, width in
                subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            }
            .max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, justifiedWidths(totalWidth: bounds.width, subviews: subviews)) {
            // Proposing the row height stretches every card surface to the
            // tallest card in the row, so short clips don't leave a gap
            // below their card.
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width + Self.spacing
        }
    }

    /// Splits `totalWidth` between the cards proportionally to their measured
    /// ideal widths: naturally narrow clips (short text, color swatches) keep
    /// a modest share while long content absorbs the rest, and the shares
    /// always sum to the full row.
    private func justifiedWidths(totalWidth: CGFloat, subviews: Subviews) -> [CGFloat] {
        let available = totalWidth - Self.spacing * CGFloat(subviews.count - 1)
        guard available > 0 else {
            return Array(repeating: 0, count: subviews.count)
        }

        let floorWidth = min(Self.minCardWidth, available / CGFloat(subviews.count))
        let ideals = subviews.map { subview in
            min(max(subview.sizeThatFits(.unspecified).width, floorWidth), available)
        }

        var widths = ideals
        var isFloored = Array(repeating: false, count: subviews.count)
        // Scale the flexible cards proportionally into the space left over by
        // floored ones; each pass either converges or floors one more card,
        // and at least one card always stays above the floor.
        for _ in subviews.indices {
            let flooredCount = isFloored.count(where: { $0 })
            let flexibleSpace = available - floorWidth * CGFloat(flooredCount)
            let flexibleIdealTotal = ideals.indices.reduce(CGFloat.zero) {
                isFloored[$1] ? $0 : $0 + ideals[$1]
            }
            var flooredAnother = false
            for index in ideals.indices {
                if isFloored[index] {
                    widths[index] = floorWidth
                } else {
                    let scaled = ideals[index] / flexibleIdealTotal * flexibleSpace
                    if scaled < floorWidth {
                        isFloored[index] = true
                        flooredAnother = true
                    } else {
                        widths[index] = scaled
                    }
                }
            }
            if !flooredAnother { break }
        }
        return widths
    }
}
