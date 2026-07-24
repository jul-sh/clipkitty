import AppKit
import ClipKittyCore
import ClipKittyMacPlatform
import ClipKittyRust
import os.signpost
import SwiftUI

private let poi = OSLog(subsystem: "com.eviljuliette.clipkitty", category: .pointsOfInterest)

private enum SpinnerState: Equatable {
    case idle
    case debouncing(task: Task<Void, Never>)
    case visible

    static func == (lhs: SpinnerState, rhs: SpinnerState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.visible, .visible), (.debouncing, .debouncing):
            return true
        default:
            return false
        }
    }

    mutating func cancel() {
        if case let .debouncing(task) = self {
            task.cancel()
        }
        self = .idle
    }
}

extension View {
    @ViewBuilder
    func clipKittyWindowGlassBackground() -> some View {
        let radius = systemWindowCornerRadius
        if #available(macOS 26.0, *) {
            if let radius {
                glassEffect(.regular.interactive(), in: .rect(cornerRadius: radius, style: .continuous))
            } else {
                glassEffect(.regular.interactive(), in: .rect)
            }
        } else {
            if let radius {
                background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            } else {
                background(.regularMaterial)
            }
        }
    }
}

// MARK: - Three-Part HStack Highlighted Text

/// SwiftUI-native text view using Three-Part HStack strategy for search highlighting.
/// Uses layout priorities to guarantee the first highlight is always visible while maximizing context.
/// - Prefix: Truncates from head (`.head`) showing "...text"
/// - Highlight: Has `.layoutPriority(1)` to claim space first, never pushed off-screen
/// - Suffix: Truncates from tail (`.tail`) showing "text..."
///
/// Uses HighlightStyler for all index calculations with proper Unicode scalar handling.
struct HighlightedTextView: View, Equatable {
    let text: String
    let highlights: [Utf16HighlightRange]
    let accentSelected: Bool
    let textScale: CGFloat
    let fontPreference: AppFontPreference

    private var textColor: Color {
        accentSelected ? .white : .primary
    }

    private var font: Font {
        let size = AppFontMetrics.size(15 * textScale, for: fontPreference)
        switch fontPreference {
        case .iosevkaCharon:
            return .custom(FontManager.sansSerifName(for: .iosevkaCharon), size: size)
        case .system:
            return .system(size: size)
        }
    }

    var body: some View {
        // Use firstTextBaseline so text aligns perfectly even with different weights
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let firstHighlight = highlights.first {
                // Use HighlightStyler so the row renderer stays on UTF-16 offsets end to end.
                let (prefix, match, suffix) = HighlightStyler.splitText(text, highlight: firstHighlight)
                let suffixStartUtf16Offset = Int(firstHighlight.utf16End)

                // 1. PREFIX: Truncates on the left ("...text")
                if !prefix.isEmpty {
                    Text(prefix)
                        .font(font)
                        .foregroundColor(textColor)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                // 2. HIGHLIGHT: High priority ensures it claims space first
                highlightedMatchView(match: match, kind: firstHighlight.kind)

                // 3. SUFFIX: Truncates on the right ("text...")
                // Apply any additional highlights that fall within suffix
                if !suffix.isEmpty {
                    suffixView(suffix: suffix, suffixStartUtf16Offset: suffixStartUtf16Offset)
                        .font(font)
                        .foregroundColor(textColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

            } else {
                // No highlights - simple text with tail truncation
                Text(text)
                    .font(font)
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        // Ensure text aligns to the left if shorter than container
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Build the highlighted match view with optional underline
    private func highlightedMatchView(match: String, kind: HighlightKind) -> some View {
        Text(HighlightStyler.attributedFragment(match, kind: kind))
            .font(font)
            .foregroundColor(textColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(1)
    }

    /// Build suffix view with any additional highlights
    @ViewBuilder
    private func suffixView(suffix: String, suffixStartUtf16Offset: Int) -> some View {
        // Check for additional highlights in the suffix (beyond the first one)
        let suffixUtf16Count = suffix.utf16.count
        let additionalHighlights = highlights.dropFirst().filter { h in
            HighlightStyler.highlightInSuffix(
                h,
                suffixStartUtf16Offset: suffixStartUtf16Offset,
                suffixUtf16Count: suffixUtf16Count
            )
        }

        if additionalHighlights.isEmpty {
            Text(suffix)
        } else {
            Text(HighlightStyler.attributedSuffix(
                suffix,
                suffixStartUtf16Offset: suffixStartUtf16Offset,
                highlights: Array(additionalHighlights)
            ))
        }
    }
}

// MARK: - Action Option Row

struct ActionOptionRow: View {
    let item: BrowserActionItem
    var isHighlighted: Bool = false
    var onHover: ((Bool) -> Void)?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: item.systemImageName)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 14, alignment: .center)

                Text(item.label)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(backgroundColor)
            }
            .animation(.easeOut(duration: 0.12), value: isHighlighted)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { onHover?($0) }
        .accessibilityIdentifier("Action_\(item.identifier)")
    }

    private var foregroundColor: Color {
        if isHighlighted { return .white }
        switch item {
        case .delete:
            return .red
        case .bookmark, .unbookmark, .copyOnly, .defaultAction:
            return .secondary
        }
    }

    private var backgroundColor: Color {
        if isHighlighted {
            switch item {
            case .delete:
                return Color.red.opacity(0.8)
            case .bookmark, .unbookmark, .copyOnly, .defaultAction:
                return .selectionBackground
            }
        }
        return Color.clear
    }
}

// MARK: - Selection Background

extension Color {
    /// Selection background matching system tint, slightly desaturated for a subtler look.
    static var selectionBackground: Color {
        Color(nsColor: .selectedContentBackgroundColor.desaturated(by: 0.10))
    }
}

private extension NSColor {
    /// Returns a new color with saturation reduced by the given fraction (0.0–1.0).
    func desaturated(by amount: CGFloat) -> NSColor {
        guard let hsb = usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        hsb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let newSaturation = max(0, s - amount)
        return NSColor(hue: h, saturation: newSaturation, brightness: b, alpha: a)
    }
}

// MARK: - Highlight Kind Color Mapping

// MARK: - Hide Scroll Indicators When System Uses Overlay Style

/// Hides scroll indicators when the system preference is "Show scroll bars: When scrolling" (overlay style).
/// Detects scrolling via ScrollView geometry and shows indicators only while actively scrolling.
/// This prevents the brief scrollbar flash when the panel appears.
struct HideScrollIndicatorsWhenOverlay: ViewModifier {
    let displayVersion: Int
    @State private var hasScrolled = false

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *), NSScroller.preferredScrollerStyle == .overlay {
            content
                .scrollIndicators(hasScrolled ? .automatic : .never)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, _ in
                    if !hasScrolled {
                        hasScrolled = true
                    }
                }
                .onChange(of: displayVersion) { _, _ in
                    hasScrolled = false
                }
        } else {
            content
        }
    }
}
