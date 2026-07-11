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

            if model.needsGlobeKey {
                InputModeSwitchButton(target: inputModeSwitchTarget)
                    .frame(width: 36, height: 30)
                    .accessibilityLabel(String(localized: "Next keyboard"))
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
                    localized: "In the Settings app, go to ClipKitty → Keyboards and turn on Allow Full Access. ClipKitty's keyboard only reads your clip history; it sends nothing anywhere."
                )
            )

        case .empty:
            KeyboardMessageView(
                systemImage: "clipboard",
                title: String(localized: "No clips yet"),
                caption: String(localized: "Open ClipKitty to load your recent clips, then they'll appear here.")
            )

        case let .ready(items):
            KeyboardCardStrip(items: items, insertText: insertText)
        }
    }
}

// MARK: - Card strip

private struct KeyboardCardStrip: View {
    let items: [KeyboardFeedStore.Item]
    let insertText: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(items) { item in
                    KeyboardCardView(item: item, insertText: insertText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Card

private struct KeyboardCardView: View {
    let item: KeyboardFeedStore.Item
    let insertText: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var showsInsertedFlash = false

    private static let cornerRadius: CGFloat = 12

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            metadataLine
            contentPreview
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 180, alignment: .topLeading)
        .frame(maxHeight: .infinity)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        )
        .overlay {
            if colorScheme == .dark {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            }
        }
        .overlay(insertedFlash)
        .contentShape(
            [.interaction, .dragPreview],
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        )
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
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
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
        let date = Date(timeIntervalSince1970: TimeInterval(item.timestampUnix))
        return Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
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
