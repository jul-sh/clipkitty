import ClipKittyBrowser
import ClipKittyCore
import ClipKittyRust
import SwiftUI
import UIKit

struct CardView: View {
    let row: DisplayRow
    @Binding var previewItemId: String?
    let isSelectionMode: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void

    @Environment(AppContainer.self) private var container
    @Environment(BrowserViewModel.self) private var viewModel
    @Environment(AppState.self) private var appState
    @Environment(HapticsClient.self) private var haptics
    @Environment(iOSSettingsStore.self) private var settings

    @State private var isShareLoading = false
    @State private var shareTask: Task<Void, Never>?
    @State private var shareRequestID: UUID?
    @State private var hostedPendingImagePlaceholders = 0

    init(
        row: DisplayRow,
        previewItemId: Binding<String?>,
        isSelectionMode: Bool = false,
        isSelected: Bool = false,
        onToggleSelection: @escaping () -> Void = {}
    ) {
        self.row = row
        _previewItemId = previewItemId
        self.isSelectionMode = isSelectionMode
        self.isSelected = isSelected
        self.onToggleSelection = onToggleSelection
    }

    /// Sans-serif card font honouring the user's typeface preference.
    private func sansFont(size: CGFloat, weight: Font.Weight? = nil) -> Font {
        AppFont.ui(settings.fontPreference, size: size, weight: weight)
    }

    /// Preview-text card font honouring the user's typeface + spacing
    /// preferences (used for raw values like text bodies, URLs, and colors).
    private func monoFont(size: CGFloat, weight: Font.Weight? = nil) -> Font {
        AppFont.preview(
            typeface: settings.fontPreference,
            style: settings.previewFontPreference,
            size: size,
            weight: weight
        )
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var metadata: ItemMetadata {
        row.metadata
    }

    private var displayExcerpt: (text: String, highlights: [Utf16HighlightRange]) {
        row.displayExcerpt
    }

    private var isBookmarked: Bool {
        metadata.tags.contains(.bookmark)
    }

    var body: some View {
        if isSelectionMode {
            selectableCard
        } else {
            // A full-screen destination can background ClipKitty before it
            // asks the item provider for promised data. Always use the managed
            // interaction so the foreground store remains available while the
            // drag is in flight.
            ExternalCopyDragHost(makePayload: makeManagedDragPayload) {
                standardInteractiveCard
                    // A UIHostingController begins a new SwiftUI environment
                    // root. Re-inject the values used by nested rich previews.
                    .environment(container)
                    .environment(viewModel)
                    .environment(appState)
                    .environment(haptics)
                    .environment(settings)
                    // Preferences do not cross a UIHostingController
                    // boundary. Bridge the image-placeholder count back into
                    // this card so the feed never advertises a settled frame
                    // while an image placeholder is still visible.
                    .onPreferenceChange(PendingImagePlaceholderCount.self) { count in
                        hostedPendingImagePlaceholders = count
                    }
            }
            .preference(
                key: PendingImagePlaceholderCount.self,
                value: hostedPendingImagePlaceholders
            )
            .onDisappear {
                cancelShare()
            }
        }
    }

    private var cardSurface: some View {
        VStack(alignment: .leading, spacing: 10) {
            metadataLine
            contentPreview
        }
        .cardSurface()
        .contentShape(
            [.interaction, .dragPreview, .contextMenuPreview],
            RoundedRectangle(cornerRadius: CardSurface.cornerRadius, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityCardLabel)
    }

    private var standardInteractiveCard: some View {
        cardSurface
            .accessibilityHint(String(localized: "Double tap to copy"))
            .accessibilityAddTraits(.isButton)
            // Advertise the drag point on the accessible SwiftUI card itself.
            // The enclosing UIKit host owns the single UIDragInteraction, but
            // must not replace or split this element's accessibility target.
            .accessibilityDragPoint(.center, description: accessibilityCardLabel)
            .onTapGesture {
                viewModel.copyOnlyItem(itemId: metadata.itemId)
            }
            .contextMenu { contextMenuActions }
    }

    private var selectableCard: some View {
        cardSurface
            .overlay {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .font(.title2.weight(.semibold))
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: CardSurface.cornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.clear,
                        lineWidth: 2
                    )
                    .allowsHitTesting(false)
            }
            .animation(.snappy, value: isSelected)
            .accessibilityHint(
                isSelected
                    ? String(localized: "Double tap to deselect")
                    : String(localized: "Double tap to select")
            )
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .onTapGesture {
                onToggleSelection()
                haptics.fire(.selection)
            }
    }

    private func makeManagedDragPayload() -> ExternalCopyDragPayload {
        makeDragPayload(externalTransferLease: appState.beginExternalTransfer())
    }

    private func makeDragPayload(
        externalTransferLease: AppExternalTransferLease?
    ) -> ExternalCopyDragPayload {
        let repository = container.repository
        return ExternalCopyDragPayload(
            descriptors: [
                ExternalCopyDragItemDescriptor(
                    itemID: metadata.itemId,
                    icon: metadata.icon
                ),
            ],
            externalTransferLease: externalTransferLease,
            fetchItem: { id in
                await repository.fetchTransferItem(id: id)
            }
        )
    }

    private var metadataLine: some View {
        HStack(spacing: 6) {
            Image(systemName: iconSymbolName)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(typeLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            sourceAppBadge

            Text(relativeTime)
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            if isBookmarked {
                Image(systemName: "bookmark.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// A small glyph badge showing the app this item was copied from when iOS
    /// has a useful representative SF Symbol. iOS can't render another app's
    /// real icon the way the Mac does (no NSWorkspace), so unmapped sources show
    /// no badge.
    ///
    /// Like the Mac (`showsSourceAppBadge`), links and files are excluded: their
    /// content-type icon already signals the origin, so a source badge is noise.
    @ViewBuilder
    private var sourceAppBadge: some View {
        if showsSourceAppBadge,
           let symbol = SourceAppIcon.symbolName(forBundleID: metadata.sourceAppBundleId)
        {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(metadata.sourceApp.map { String(localized: "From \($0)") } ?? "")
        }
    }

    /// Whether this item's type should carry a source-app badge. Mirrors the
    /// Mac's `showsSourceAppBadge`: text/image/color yes, links no. (Files are
    /// filtered out of the iOS feed entirely.)
    private var showsSourceAppBadge: Bool {
        switch metadata.icon {
        case let .symbol(iconType):
            return iconType != .link && iconType != .file
        case .thumbnail, .colorSwatch:
            return true
        }
    }

    // MARK: - Content preview

    @ViewBuilder
    private var contentPreview: some View {
        switch metadata.icon {
        case let .symbol(iconType):
            symbolContentPreview(iconType: iconType)

        case let .colorSwatch(rgba):
            colorSwatchPreview(rgba: rgba)

        case let .thumbnail(bytes):
            thumbnailPreview(bytes: bytes)
        }
    }

    @ViewBuilder
    private func highlightedText(_ text: String, highlights: [Utf16HighlightRange], font: Font) -> some View {
        if highlights.isEmpty {
            Text(text)
                .font(font)
                .foregroundStyle(.primary)
        } else {
            Text(HighlightAttributedStringBuilder.attributedText(text, highlights: highlights))
                .font(font)
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func symbolContentPreview(iconType: IconType) -> some View {
        switch iconType {
        case .text:
            highlightedText(displayExcerpt.text, highlights: displayExcerpt.highlights, font: monoFont(size: 15))
                .lineLimit(8)

        case .link:
            CardLinkPreview(
                itemId: metadata.itemId,
                url: displayExcerpt.text,
                highlights: displayExcerpt.highlights,
                sansFont: sansFont,
                monoFont: monoFont
            )

        case .image:
            HStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                highlightedText(displayExcerpt.text, highlights: displayExcerpt.highlights, font: sansFont(size: 15))
                    .lineLimit(2)
            }

        case .file:
            // File items are filtered out of the iOS feed
            EmptyView()

        case .color:
            // Fallback for symbol-based color (shouldn't normally hit this path)
            highlightedText(displayExcerpt.text, highlights: displayExcerpt.highlights, font: monoFont(size: 15))
        }
    }

    private func colorSwatchPreview(rgba: UInt32) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colorFromRGBA(rgba))
                .frame(width: 40, height: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
                )

            highlightedText(
                displayExcerpt.highlights.isEmpty ? hexStringFromRGBA(rgba) : displayExcerpt.text,
                highlights: displayExcerpt.highlights,
                font: monoFont(size: 15)
            )
        }
    }

    private func thumbnailPreview(bytes: Data) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Aspect-fit, height-capped: the card shows the whole image (the
            // full-resolution copy lives in the preview screen, but cropping
            // the card thumbnail loses the subject — marketing review flagged
            // the "FAST" cat card losing its caption to the crop).
            //
            // Fit, not fill, on purpose: an aspect-fill image reports a size
            // that COVERS its proposal, so a wide image inside a packed
            // `JustifiedCardRow` slot reported wider than the slot and drew
            // past the card edge into the row gutter. A fit image never
            // exceeds its proposal, so it cannot overflow its slot. (Fill was
            // originally introduced on the theory that fit's proposal-
            // dependent sizing deadlocked JustifiedCardRow; the hang sampler
            // on run 28768712784 disproved that — the freeze was HEIC decodes
            // wedging the concurrency pool, fixed in DecodedImageView — and
            // the layout was never the culprit.)
            CardImagePreview(itemId: metadata.itemId, thumbnailBytes: bytes)
                .frame(maxWidth: .infinity, maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if !displayExcerpt.text.isEmpty {
                highlightedText(displayExcerpt.text, highlights: displayExcerpt.highlights, font: sansFont(size: 15))
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenuActions: some View {
        Button {
            viewModel.copyOnlyItem(itemId: metadata.itemId)
        } label: {
            Label(String(localized: "Copy"), systemImage: "doc.on.doc")
        }

        Button {
            previewItemId = metadata.itemId
        } label: {
            Label(String(localized: "Preview"), systemImage: "eye")
        }

        Button {
            if isBookmarked {
                viewModel.removeTag(.bookmark, fromItem: metadata.itemId)
                appState.showToast(.unbookmarked)
            } else {
                viewModel.addTag(.bookmark, toItem: metadata.itemId)
                appState.showToast(.bookmarked)
            }
            haptics.fire(.selection)
        } label: {
            Label(
                isBookmarked ? String(localized: "Remove Bookmark") : String(localized: "Bookmark"),
                systemImage: isBookmarked ? "bookmark.slash" : "bookmark"
            )
        }

        Button {
            shareItem()
        } label: {
            Label(isShareLoading ? String(localized: "Loading…") : String(localized: "Share"), systemImage: "square.and.arrow.up")
        }
        .disabled(isShareLoading)

        Button(role: .destructive) {
            viewModel.deleteItem(itemId: metadata.itemId)
            haptics.fire(.destructive)
        } label: {
            Label(String(localized: "Delete"), systemImage: "trash")
        }
    }

    // MARK: - Share

    private func shareItem() {
        cancelShare()
        let requestID = UUID()
        shareRequestID = requestID
        isShareLoading = true
        let task = Task { @MainActor in
            defer { finishShare(requestID: requestID) }
            guard !Task.isCancelled else { return }
            guard let item = await container.repository.fetchTransferItem(id: metadata.itemId) else {
                guard isCurrentShare(requestID: requestID) else { return }
                appState.showToast(.addFailed(String(localized: "Could not load item")))
                return
            }
            guard isCurrentShare(requestID: requestID) else { return }
            guard let payload = await SharePresenter.prepare(item: item) else {
                guard isCurrentShare(requestID: requestID) else { return }
                appState.showToast(.addFailed(String(localized: "Could not load item")))
                return
            }
            guard isCurrentShare(requestID: requestID) else { return }
            SharePresenter.present(payload: payload)
        }
        shareTask = task
        guard appState.registerForegroundTask(id: requestID, task: task) else {
            cancelShare()
            return
        }
    }

    @MainActor
    private func isCurrentShare(requestID: UUID) -> Bool {
        !Task.isCancelled && shareRequestID == requestID
    }

    @MainActor
    private func cancelShare() {
        shareRequestID = nil
        shareTask?.cancel()
        shareTask = nil
        isShareLoading = false
    }

    @MainActor
    private func finishShare(requestID: UUID) {
        appState.finishForegroundTask(id: requestID)
        guard shareRequestID == requestID else { return }
        shareRequestID = nil
        shareTask = nil
        isShareLoading = false
    }

    // MARK: - Helpers

    private var accessibilityCardLabel: String {
        var parts = [typeLabel]
        if isBookmarked { parts.append("bookmarked") }
        let preview = displayExcerpt.text.prefix(100)
        if !preview.isEmpty { parts.append(String(preview)) }
        parts.append(relativeTime)
        return parts.joined(separator: ", ")
    }

    private var iconSymbolName: String {
        switch metadata.icon {
        case let .symbol(iconType):
            return iconType.sfSymbolName
        case .colorSwatch:
            return "paintpalette"
        case .thumbnail:
            return "photo"
        }
    }

    private var typeLabel: String {
        switch metadata.icon {
        case let .symbol(iconType):
            switch iconType {
            case .text: return String(localized: "Text")
            case .link: return String(localized: "Link")
            case .image: return String(localized: "Image")
            case .color: return String(localized: "Color")
            case .file: return String(localized: "File")
            }
        case .colorSwatch:
            return String(localized: "Color")
        case .thumbnail:
            return String(localized: "Image")
        }
    }

    private var relativeTime: String {
        let date = Date(timeIntervalSince1970: TimeInterval(metadata.timestampUnix))
        return Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func colorFromRGBA(_ rgba: UInt32) -> Color {
        let r = Double((rgba >> 24) & 0xFF) / 255.0
        let g = Double((rgba >> 16) & 0xFF) / 255.0
        let b = Double((rgba >> 8) & 0xFF) / 255.0
        let a = Double(rgba & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b, opacity: a)
    }

    private func hexStringFromRGBA(_ rgba: UInt32) -> String {
        let r = (rgba >> 24) & 0xFF
        let g = (rgba >> 16) & 0xFF
        let b = (rgba >> 8) & 0xFF
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

/// Renders the full-resolution image for a card preview.
///
/// The feed's `ItemMetadata.icon.thumbnail` payload is a ~64px JPEG built for
/// list-row icons; on iPad cards stretch wide enough that scaling that
/// thumbnail produces visibly pixelated marketing screenshots. We instead
/// fetch the original image bytes (via `BrowserStoreClient.fetchItem`) and
/// render those, falling back to the small thumbnail until the load
/// resolves so the card never flashes empty.
private struct CardImagePreview: View {
    let itemId: String
    let thumbnailBytes: Data

    @Environment(AppContainer.self) private var container
    @Environment(AppState.self) private var appState

    @State private var fullImageBytes: Data?

    var body: some View {
        DecodedImageView(
            namespace: fullImageBytes == nil ? "card-thumbnail" : "card-full",
            itemId: itemId,
            data: fullImageBytes ?? thumbnailBytes,
            // Fit shows the whole image and can never report wider than its
            // packed-row slot; see the note in `thumbnailPreview`.
            contentMode: .fit
        ) {
            // 16:9 stand-in so the card reserves a plausible image box until
            // the decode lands, instead of jumping from empty to full height.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.secondary.opacity(0.1))
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(
                    Image(systemName: "photo")
                        .font(.title)
                        .foregroundStyle(.secondary)
                )
        }
        .task(id: itemId) {
            guard fullImageBytes == nil else { return }
            let requestID = UUID()
            let task = Task { @MainActor in
                defer { appState.finishForegroundTask(id: requestID) }
                guard !Task.isCancelled else { return }
                // Registered with ImageLoadActivity so the feed's settled
                // signal spans the whole pipeline: this fetch, then the decode
                // it kicks off in DecodedImageView.
                ImageLoadActivity.shared.begin()
                defer { ImageLoadActivity.shared.end() }
                let storeClient = container.storeClient
                guard let item = await storeClient.fetchItem(id: itemId) else { return }
                guard !Task.isCancelled else { return }
                if case let .image(data, _, _) = item.content {
                    fullImageBytes = data
                }
            }
            guard appState.registerForegroundTask(id: requestID, task: task) else { return }
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
    }
}

/// A rich link card for the feed, mirroring how the Mac surfaces links in its
/// preview pane (title + preview image) rather than the bare `globe + URL` the
/// iOS feed used before.
///
/// The feed's `DisplayRow` only carries the URL string, not the link's fetched
/// `metadataState`, so — like `CardImagePreview` — we fetch the persisted item
/// (`fetchItem`, which returns the stored `.loaded` payload when previews have
/// been generated) and upgrade the card in place. We render the loaded title and
/// image data directly with `Text` + `DecodedImageView` instead of embedding the
/// heavyweight `LPLinkView` per row, which would churn UIKit views while
/// scrolling. The detail screen keeps the native `LinkPreviewView`.
private struct CardLinkPreview: View {
    let itemId: String
    let url: String
    let highlights: [Utf16HighlightRange]
    let sansFont: (CGFloat, Font.Weight?) -> Font
    let monoFont: (CGFloat, Font.Weight?) -> Font

    @Environment(AppContainer.self) private var container
    @Environment(AppState.self) private var appState

    @State private var metadataState: LinkMetadataState = .pending

    private var loadedPayload: LinkMetadataPayload? {
        if case let .loaded(payload) = metadataState { return payload }
        return nil
    }

    private var host: String {
        URL(string: url)?.host ?? url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let imageData = loadedPayload?.imageData {
                DecodedImageView(
                    namespace: "card-link",
                    itemId: itemId,
                    data: imageData,
                    contentMode: .fill
                ) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.secondary.opacity(0.1))
                        .frame(height: 140)
                }
                .frame(maxWidth: .infinity, maxHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let title = loadedPayload?.title, !title.isEmpty {
                Text(title)
                    .font(sansFont(15, .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(host)
                    .font(sansFont(13, .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            highlightedURL
                .lineLimit(loadedPayload == nil ? 2 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: itemId) {
            // The card already renders host + URL immediately; this fills in the
            // title/image when the persisted item carries loaded metadata.
            guard case .pending = metadataState else { return }
            let requestID = UUID()
            let task = Task { @MainActor in
                defer { appState.finishForegroundTask(id: requestID) }
                guard !Task.isCancelled else { return }
                ImageLoadActivity.shared.begin()
                defer { ImageLoadActivity.shared.end() }
                guard let item = await container.storeClient.fetchItem(id: itemId) else { return }
                guard !Task.isCancelled else { return }
                if case let .link(_, state) = item.content {
                    metadataState = state
                }
            }
            guard appState.registerForegroundTask(id: requestID, task: task) else { return }
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
    }

    @ViewBuilder
    private var highlightedURL: some View {
        if highlights.isEmpty {
            Text(url)
                .font(monoFont(12, nil))
                .foregroundStyle(.tertiary)
        } else {
            Text(HighlightAttributedStringBuilder.attributedText(url, highlights: highlights))
                .font(monoFont(12, nil))
                .foregroundStyle(.tertiary)
        }
    }
}
