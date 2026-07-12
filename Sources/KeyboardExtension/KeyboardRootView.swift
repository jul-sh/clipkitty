import ClipKittyShared
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The keyboard's whole surface: a header row (wordmark + globe key) above
/// the clip cards. No keys — tap a card to insert it, or drag it into the
/// host app.
struct KeyboardRootView: View {
    let model: KeyboardFeedModel
    let insertText: (String) -> Void
    let openSearchInApp: () -> Void
    weak var inputModeSwitchTarget: UIInputViewController?

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.bottom, 4)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: "ClipKitty")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer()

            // The keyboard has no search of its own (for now); this hands
            // off to the app's search.
            Button(action: openSearchInApp) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Search in ClipKitty"))
            .accessibilityIdentifier("keyboard.searchButton")

            if model.needsGlobeKey {
                InputModeSwitchButton(target: inputModeSwitchTarget)
                    .frame(width: 36, height: 30)
                    .accessibilityLabel(String(localized: "Next keyboard"))
                    .accessibilityIdentifier("keyboard.globeKey")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .needsFullAccess:
            KeyboardMessageView(
                systemImage: "lock",
                title: String(localized: "Allow Full Access to see your clips"),
                caption: String(
                    localized: "In the Settings app, go to ClipKitty → Keyboards and turn on Allow Full Access. The keyboard reads your clip history and saves new clips to it; nothing leaves your device."
                )
            )

        case .empty:
            KeyboardMessageView(
                systemImage: "clipboard",
                title: String(localized: "No clips yet"),
                caption: String(localized: "Copy something, or open ClipKitty to load your recent clips — they'll appear here.")
            )

        case let .ready(cards):
            KeyboardCardStrip(cards: cards, insertText: insertText, openSearchInApp: openSearchInApp)
        }
    }
}

// MARK: - Card strip

private struct KeyboardCardStrip: View {
    let cards: [KeyboardFeedModel.Card]
    let insertText: (String) -> Void
    let openSearchInApp: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(cards) { card in
                    switch card {
                    case let .clip(item):
                        KeyboardCardView(item: item, insertText: insertText)
                    case let .capturedImage(imageCard):
                        CapturedImageCardView(card: imageCard)
                    }
                }

                // The strip only holds the newest clips (see
                // KeyboardFeedStore.maxItems); scrolling past the end offers
                // the rest via the app's search.
                SearchInAppCardView(openSearchInApp: openSearchInApp)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        // Only exists in the ready state, so automation can tell "cards are
        // showing" apart from the full-access / empty messages.
        .accessibilityIdentifier("keyboard.cardStrip")
    }
}

// MARK: - Card chrome

private enum KeyboardCardMetrics {
    static let cornerRadius: CGFloat = 12
    static let width: CGFloat = 180

    static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// "Now" under a minute — RelativeDateTimeFormatter's "0 sec. ago" reads
    /// like a stopwatch, and freshly-captured cards always land here.
    static func relativeTime(fromUnix timestampUnix: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestampUnix))
        if Date().timeIntervalSince(date) < 60 {
            return String(localized: "Now")
        }
        return relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct KeyboardCardSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(width: KeyboardCardMetrics.width, alignment: .topLeading)
            .frame(maxHeight: .infinity)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: KeyboardCardMetrics.cornerRadius, style: .continuous)
            )
            .overlay {
                if colorScheme == .dark {
                    RoundedRectangle(cornerRadius: KeyboardCardMetrics.cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                }
            }
            .contentShape(
                [.interaction, .dragPreview],
                RoundedRectangle(cornerRadius: KeyboardCardMetrics.cornerRadius, style: .continuous)
            )
    }
}

// MARK: - Card

private struct KeyboardCardView: View {
    let item: KeyboardFeedStore.Item
    let insertText: (String) -> Void

    @State private var showsInsertedFlash = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            metadataLine
            contentPreview
            Spacer(minLength: 0)
        }
        .modifier(KeyboardCardSurface())
        .overlay(insertedFlash)
        .onTapGesture(perform: insert)
        .onDrag(makeDragProvider)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityCardLabel)
        .accessibilityHint(String(localized: "Double tap to insert"))
        .accessibilityAddTraits(.isButton)
    }

    private var metadataLine: some View {
        HStack(spacing: 6) {
            Image(systemName: iconSymbolName)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let sourceApp = item.sourceApp, !sourceApp.isEmpty {
                Text(sourceApp)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(relativeTime)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var contentPreview: some View {
        switch item.kind {
        case .text:
            Text(excerpt)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(6)
                .multilineTextAlignment(.leading)

        case .link:
            VStack(alignment: .leading, spacing: 4) {
                if let host = URL(string: item.text)?.host {
                    Text(host)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Text(excerpt)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
            }

        case .color:
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(swatchColor)
                    .frame(width: 28, height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
                    )
                Text(excerpt)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var insertedFlash: some View {
        if showsInsertedFlash {
            RoundedRectangle(cornerRadius: KeyboardCardMetrics.cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                )
                .transition(.opacity)
        }
    }

    // MARK: - Actions

    private func insert() {
        insertText(item.text)
        withAnimation(.easeIn(duration: 0.1)) {
            showsInsertedFlash = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.easeOut(duration: 0.2)) {
                showsInsertedFlash = false
            }
        }
    }

    /// Text is provided eagerly (it's already in memory); links also offer a
    /// URL representation so drop targets like browsers get the richer type.
    private func makeDragProvider() -> NSItemProvider {
        let provider = NSItemProvider(object: item.text as NSString)
        if item.kind == .link, let url = URL(string: item.text) {
            provider.registerObject(url as NSURL, visibility: .all)
        }
        return provider
    }

    // MARK: - Presentation helpers

    /// Cards only ever show the first few lines; feeding multi-hundred-KB
    /// clips to `Text` wastes layout work, so cap what the view sees.
    private var excerpt: String {
        String(item.text.prefix(300))
    }

    private var iconSymbolName: String {
        switch item.kind {
        case .text: return "doc.text"
        case .link: return "globe"
        case .color: return "paintpalette"
        }
    }

    private var relativeTime: String {
        KeyboardCardMetrics.relativeTime(fromUnix: item.timestampUnix)
    }

    private var swatchColor: Color {
        guard let rgba = item.colorRGBA else { return .clear }
        let r = Double((rgba >> 24) & 0xFF) / 255.0
        let g = Double((rgba >> 16) & 0xFF) / 255.0
        let b = Double((rgba >> 8) & 0xFF) / 255.0
        let a = Double(rgba & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b, opacity: a)
    }

    private var accessibilityCardLabel: String {
        var parts: [String] = []
        if let sourceApp = item.sourceApp, !sourceApp.isEmpty {
            parts.append(sourceApp)
        }
        parts.append(String(excerpt.prefix(100)))
        parts.append(relativeTime)
        return parts.joined(separator: ", ")
    }
}

// MARK: - Captured image card

/// An image just captured from the pasteboard. It can't be inserted as text,
/// so the card is a drag source: drop it into the host app. The bytes stay on
/// disk in the pending queue and are read lazily when a drop lands.
private struct CapturedImageCardView: View {
    let card: KeyboardFeedModel.CapturedImageCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(String(localized: "Image"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(KeyboardCardMetrics.relativeTime(fromUnix: card.timestampUnix))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let thumbnail = card.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.secondary.opacity(0.1))
                    .overlay(
                        Image(systemName: "photo")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    )
            }

            HStack(spacing: 4) {
                Image(systemName: "hand.draw")
                    .font(.caption2)
                Text(String(localized: "Drag to use"))
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)
        }
        .modifier(KeyboardCardSurface())
        .onDrag(makeDragProvider)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Image from your clipboard"))
        .accessibilityHint(String(localized: "Drag into the app to use it"))
    }

    private func makeDragProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let fileURL = card.fileURL
        provider.registerDataRepresentation(
            forTypeIdentifier: card.utType.identifier,
            visibility: .all
        ) { completion in
            // Read lazily: the bytes may be several MB, and most drags never
            // leave the keyboard.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let data = try Data(contentsOf: fileURL)
                    completion(data, nil)
                } catch {
                    completion(nil, error)
                }
            }
            return nil
        }
        return provider
    }
}

// MARK: - Search hand-off card

/// The strip's last card: the keyboard only carries the newest clips, so
/// anything older means a trip to the app — this card lands there with
/// search already open.
private struct SearchInAppCardView: View {
    let openSearchInApp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(String(localized: "Search"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            Text(String(localized: "Looking for an older clip?"))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)

            Text(String(localized: "The keyboard shows recent clips only."))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Text(String(localized: "Search in ClipKitty"))
                Image(systemName: "arrow.up.forward")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.tint)
        }
        .modifier(KeyboardCardSurface())
        .onTapGesture(perform: openSearchInApp)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Search all your clips in ClipKitty"))
        .accessibilityIdentifier("keyboard.searchCard")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Status messages

private struct KeyboardMessageView: View {
    let systemImage: String
    let title: String
    let caption: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Globe key

/// The system requires keyboards to offer a way to switch input modes when
/// `needsInputModeSwitchKey` is true. Switching is only honored when the
/// touch goes through `handleInputModeList(from:with:)` on the input view
/// controller (long-press shows the keyboard picker), which needs a UIKit
/// control target — SwiftUI gestures can't drive it.
private struct InputModeSwitchButton: UIViewRepresentable {
    weak var target: UIInputViewController?

    func makeUIView(context _: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.tintColor = .secondaryLabel
        if let target {
            button.addTarget(
                target,
                action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                for: .allTouchEvents
            )
        }
        return button
    }

    func updateUIView(_: UIButton, context _: Context) {}
}
