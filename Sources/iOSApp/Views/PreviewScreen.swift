import ClipKittyBrowser
import ClipKittyContentServices
import ClipKittyCore
import ClipKittyRust
import SwiftUI
import UIKit

struct PreviewScreen: View {
    let itemId: String

    @Environment(AppContainer.self) private var container
    @Environment(BrowserViewModel.self) private var viewModel
    @Environment(AppState.self) private var appState
    @Environment(HapticsClient.self) private var haptics
    @Environment(iOSSettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    /// Preview-text font honouring the user's typeface + spacing preferences.
    private func previewFont(size: CGFloat) -> Font {
        AppFont.preview(typeface: settings.fontPreference, style: settings.previewFontPreference, size: size)
    }

    @State private var showDeleteConfirmation = false

    #if ENABLE_TEST_FIXTURES
        private let isUITestPreviewDebugEnabled = CommandLine.arguments.contains("--use-simulated-db")
    #endif
    private static let detailDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        selectionContent
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .bottomBar)
            .safeAreaInset(edge: .bottom) {
                actionBar
            }
            .alert(String(localized: "Delete Item"), isPresented: $showDeleteConfirmation) {
                Button(String(localized: "Delete"), role: .destructive) {
                    viewModel.deleteItem(itemId: itemId)
                    haptics.fire(.destructive)
                    dismiss()
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete this item? This cannot be undone.", comment: "Delete confirmation message")
            }
            .onAppear {
                viewModel.select(itemId: itemId, origin: .click)
            }
    }

    // MARK: - Navigation Title

    private var navigationTitle: String {
        guard case let .selected(selectedItemState) = viewModel.selection,
              selectedItemState.item.itemMetadata.itemId == itemId
        else {
            return String(localized: "Detail")
        }
        let item = selectedItemState.item
        switch item.content {
        case .text: return String(localized: "Text")
        case .link: return String(localized: "Link")
        case .image: return String(localized: "Image")
        case .color: return String(localized: "Color")
        case .file: return String(localized: "File")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var selectionContent: some View {
        switch viewModel.selection {
        case let .selected(selectedItemState)
            where selectedItemState.item.itemMetadata.itemId == itemId:
            contentView(for: selectedItemState)
        case let .loading(loadingItemId, _, phase) where loadingItemId == itemId:
            ZStack {
                Color.clear
                switch phase {
                case .waitingForSpinner:
                    EmptyView()
                case .showingSpinner:
                    ProgressView(String(localized: "Loading..."))
                }
            }
        case let .failed(failedItemId, _) where failedItemId == itemId:
            ContentUnavailableView(
                String(localized: "Unable to load preview"),
                systemImage: "exclamationmark.triangle"
            )
        case .none, .loading, .selected, .failed:
            Color.clear
        }
    }

    private func contentView(for selectedItemState: SelectedItemState) -> some View {
        ZStack {
            contentSection(for: selectedItemState)
            switch selectedItemState.previewState {
            case .loadingDecoration(_, .showingSpinner):
                ProgressView()
            case .plain, .loadingDecoration(_, .waitingForSpinner), .highlighted:
                EmptyView()
            }
        }
        .overlay(alignment: .topLeading) {
            #if ENABLE_TEST_FIXTURES
                if isUITestPreviewDebugEnabled {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(PreviewDebugLabelFormatter.label(
                            text: selectedItemState.item.content.textContent,
                            itemId: selectedItemState.item.itemMetadata.itemId,
                            previewState: selectedItemState.previewState
                        ))
                        .accessibilityIdentifier("PreviewHighlightDebug")
                }
            #endif
        }
    }

    @ViewBuilder
    private func contentSection(for selectedItemState: SelectedItemState) -> some View {
        let item = selectedItemState.item
        switch item.content {
        case .text:
            let previewText = viewModel.effectiveContent(for: item).textContent
            let decoration = selectedItemState.displayDecoration(for: viewModel.editSession)
            TextPreviewView(
                itemId: item.itemMetadata.itemId,
                text: previewText,
                highlights: decoration?.highlights ?? [],
                initialScrollHighlightIndex: decoration?.initialScrollHighlightIndex,
                isEditable: {
                    switch viewModel.editSession {
                    case let .dirty(dirtyId, _) where dirtyId != item.itemMetadata.itemId,
                         let .suspendedDirty(dirtyId, _) where dirtyId != item.itemMetadata.itemId:
                        return false
                    case .inactive, .focused, .dirty, .suspendedDirty:
                        return true
                    }
                }(),
                fontPreference: settings.fontPreference,
                previewStyle: settings.previewFontPreference,
                onTextChange: { newText in
                    viewModel.onTextEdit(
                        newText,
                        for: item.itemMetadata.itemId,
                        originalContent: item.content
                    )
                },
                onEditingStateChange: { editing in
                    viewModel.onEditingStateChange(editing, for: item.itemMetadata.itemId)
                }
            )
        case let .color(value):
            let decoration = selectedItemState.displayDecoration(for: viewModel.editSession)
            VStack(spacing: 0) {
                // Color swatch at top
                RoundedRectangle(cornerRadius: 16)
                    .fill(color(from: value))
                    .frame(height: 120)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                // Color value text in TextKit 2 renderer (supports highlights + editing)
                TextPreviewView(
                    itemId: item.itemMetadata.itemId,
                    text: value,
                    highlights: decoration?.highlights ?? [],
                    initialScrollHighlightIndex: decoration?.initialScrollHighlightIndex,
                    isEditable: false,
                    fontPreference: settings.fontPreference,
                    previewStyle: settings.previewFontPreference
                )
            }
        case let .link(url, metadataState):
            let decoration = selectedItemState.previewState.decoration
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    linkContent(url: url, metadataState: metadataState, highlights: decoration?.highlights ?? [])
                    Divider()
                    metadataSection(for: item)
                }
                .cardSurface()
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        case let .image(data, description, _):
            let decoration = selectedItemState.previewState.decoration
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    imageContent(data: data, description: description, highlights: decoration?.highlights ?? [])
                    Divider()
                    metadataSection(for: item)
                }
                .cardSurface()
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        case .file:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("File items are not supported on iPhone.", comment: "Unsupported content type message")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Divider()
                    metadataSection(for: item)
                }
                .cardSurface()
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
    }

    private func color(from hex: String) -> Color {
        let sanitized = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let int = UInt64(sanitized, radix: 16) else { return .gray }

        let r: Double
        let g: Double
        let b: Double
        let a: Double

        switch sanitized.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
            a = 1.0
        case 8:
            r = Double((int >> 24) & 0xFF) / 255.0
            g = Double((int >> 16) & 0xFF) / 255.0
            b = Double((int >> 8) & 0xFF) / 255.0
            a = Double(int & 0xFF) / 255.0
        default:
            return .gray
        }

        return Color(red: r, green: g, blue: b, opacity: a)
    }

    // MARK: - Link Content

    private func linkContent(url: String, metadataState: LinkMetadataState, highlights: [Utf16HighlightRange]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            LinkPreviewView(url: url, metadataState: metadataState)
                .frame(maxWidth: .infinity)

            if highlights.isEmpty {
                Text(url)
                    .font(previewFont(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(HighlightAttributedStringBuilder.attributedText(url, highlights: highlights))
                    .font(previewFont(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Image Content

    private func imageContent(data: Data, description: String, highlights: [Utf16HighlightRange]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DecodedImageView(
                namespace: "preview-image",
                itemId: itemId,
                data: data
            ) {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !description.isEmpty {
                if highlights.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(HighlightAttributedStringBuilder.attributedText(description, highlights: highlights))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Metadata Section

    private func metadataSection(for item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details", comment: "Section header for item metadata")
                .font(.headline)

            LabeledContent(String(localized: "Type"), value: navigationTitle)

            if let sourceApp = item.itemMetadata.sourceApp {
                LabeledContent(String(localized: "Source")) {
                    HStack(spacing: 6) {
                        if let symbol = SourceAppIcon.symbolName(forBundleID: item.itemMetadata.sourceAppBundleId) {
                            Image(systemName: symbol)
                                .foregroundStyle(.secondary)
                        }
                        Text(sourceApp)
                    }
                }
            }

            LabeledContent(String(localized: "Time")) {
                Text(formattedDate(from: item.itemMetadata.timestampUnix))
            }

            LabeledContent(String(localized: "Bookmarked")) {
                Text(isBookmarked(item) ? String(localized: "Yes") : String(localized: "No"))
            }
        }
        .font(.subheadline)
    }

    private func formattedDate(from unix: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        return Self.detailDateFormatter.string(from: date)
    }

    // MARK: - Action Bar

    @ViewBuilder
    private var actionBar: some View {
        if let item = viewModel.selectedItemState?.item {
            switch viewModel.editSession {
            case let .dirty(dirtyId, _) where dirtyId == item.itemMetadata.itemId:
                // Dirty state: show Save and Cancel only
                GlassEffectContainer(spacing: 20) {
                    HStack(spacing: 20) {
                        Button {
                            viewModel.discardCurrentEdit()
                        } label: {
                            Text(String(localized: "Cancel"))
                                .font(.body.weight(.medium))
                                .frame(height: 52)
                                .padding(.horizontal, 20)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)

                        Button {
                            viewModel.commitCurrentEdit()
                        } label: {
                            Text(String(localized: "Save"))
                                .font(.body.weight(.semibold))
                                .frame(height: 52)
                                .padding(.horizontal, 20)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            case .inactive, .focused, .dirty, .suspendedDirty:
                // Normal state: standard action bar
                GlassEffectContainer(spacing: 20) {
                    HStack(spacing: 20) {
                        // Left circle: Share
                        Button {
                            SharePresenter.present(item: item)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.body.weight(.medium))
                                .frame(width: 52, height: 52)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)

                        // Center capsule: Bookmark, Copy
                        HStack(spacing: 0) {
                            Button {
                                toggleBookmark(for: item)
                            } label: {
                                Image(systemName: isBookmarked(item) ? "bookmark.slash" : "bookmark")
                                    .font(.body.weight(.medium))
                                    .frame(width: 52, height: 52)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                container.clipboardService.copy(content: item.content)
                                haptics.fire(.copy)
                                appState.showToast(.copied)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.body.weight(.medium))
                                    .frame(width: 52, height: 52)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .glassEffect(.regular.interactive(), in: .capsule)

                        // Right circle: Delete
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.body.weight(.medium))
                                .frame(width: 52, height: 52)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Helpers

    private func isBookmarked(_ item: ClipboardItem) -> Bool {
        item.itemMetadata.tags.contains(.bookmark)
    }

    private func toggleBookmark(for item: ClipboardItem) {
        if isBookmarked(item) {
            viewModel.removeTag(.bookmark, fromItem: item.itemMetadata.itemId)
            haptics.fire(.selection)
            appState.showToast(.unbookmarked)
        } else {
            viewModel.addTag(.bookmark, toItem: item.itemMetadata.itemId)
            haptics.fire(.selection)
            appState.showToast(.bookmarked)
        }
    }
}
