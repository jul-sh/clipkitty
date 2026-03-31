import ClipKittyRust
import SwiftUI
import UIKit

struct ClipboardDetailView: View {
    @EnvironmentObject private var store: iOSClipboardStore
    let itemId: String

    @State private var item: ClipboardItem?
    @State private var isLoading = true
    @State private var copiedFeedback = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        contentView(item: item)
                        metadataSection(item: item)
                    }
                    .padding()
                }
                .navigationTitle(contentTitle(item: item))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            copyToClipboard(item: item)
                        } label: {
                            Label(
                                copiedFeedback ? "Copied!" : "Copy",
                                systemImage: copiedFeedback
                                    ? "checkmark"
                                    : "doc.on.doc"
                            )
                        }
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            shareItem(item: item)
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Item Not Found",
                    systemImage: "questionmark.circle",
                    description: Text(
                        "This item may have been deleted."
                    )
                )
            }
        }
        .task {
            item = await store.fetchItem(id: itemId)
            isLoading = false
        }
    }

    // MARK: - Content Views

    @ViewBuilder
    private func contentView(item: ClipboardItem) -> some View {
        switch item.content {
        case let .text(text):
            textContentView(text: text)

        case let .image(data, description, _):
            imageContentView(data: Data(data), description: description)

        case let .color(colorString):
            colorContentView(colorString: colorString)

        case let .link(url, metadata):
            linkContentView(url: url, metadata: metadata)

        case let .file(displayName, entries):
            fileContentView(displayName: displayName, entries: entries)
        }
    }

    @ViewBuilder
    private func textContentView(text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Content")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func imageContentView(data: Data, description: String) -> some View
    {
        VStack(alignment: .leading, spacing: 8) {
            if let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 2)

                HStack {
                    Text(
                        "\(Int(uiImage.size.width)) x \(Int(uiImage.size.height))"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Spacer()

                    Text(FormattingHelpers.formatBytes(data.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func colorContentView(colorString: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 16)
                .fill(parseColor(colorString))
                .frame(height: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.quaternary, lineWidth: 1)
                )

            HStack {
                Text(colorString)
                    .font(.system(.title3, design: .monospaced))
                    .textSelection(.enabled)

                Spacer()

                Button {
                    UIPasteboard.general.string = colorString
                    showCopiedFeedback()
                } label: {
                    Label("Copy Value", systemImage: "doc.on.doc")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func linkContentView(
        url: String,
        metadata: LinkMetadata?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let metadata, let imageData = metadata.imageData {
                if let uiImage = UIImage(data: Data(imageData)) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                if let metadata {
                    if let title = metadata.title, !title.isEmpty {
                        Text(title)
                            .font(.headline)
                    }
                    if let description = metadata.description,
                       !description.isEmpty
                    {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }

                Link(url, destination: URL(string: url)!)
                    .font(.subheadline)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func fileContentView(
        displayName: String,
        entries: [FileEntry]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Files")
                .font(.headline)
                .foregroundStyle(.secondary)

            ForEach(Array(entries.enumerated()), id: \.offset) {
                _, entry in
                HStack(spacing: 10) {
                    Image(systemName: "doc")
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.filename)
                            .font(.subheadline)
                        Text(entry.path)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if entry.fileSize > 0 {
                        Text(FormattingHelpers.formatBytes(Int(entry.fileSize)))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(10)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Metadata Section

    @ViewBuilder
    private func metadataSection(item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.vertical, 4)

            Text("Details")
                .font(.headline)
                .foregroundStyle(.secondary)

            LabeledContent("Copied") {
                Text(
                    FormattingHelpers.formatDate(
                        timestampUnix: item.itemMetadata.timestampUnix
                    )
                )
                .foregroundStyle(.secondary)
            }
            .font(.subheadline)

            if let bundleId = item.itemMetadata.sourceAppBundleId,
               !bundleId.isEmpty
            {
                LabeledContent("Source") {
                    Text(bundleId)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }

            if item.itemMetadata.tags.contains(.bookmark) {
                Label("Bookmarked", systemImage: "bookmark.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Actions

    private func copyToClipboard(item: ClipboardItem) {
        switch item.content {
        case let .text(text):
            UIPasteboard.general.string = text

        case let .image(data, _, _):
            if let image = UIImage(data: Data(data)) {
                UIPasteboard.general.image = image
            }

        case let .color(colorString):
            UIPasteboard.general.string = colorString

        case let .link(url, _):
            UIPasteboard.general.url = URL(string: url)

        case let .file(_, entries):
            if let first = entries.first {
                UIPasteboard.general.string = first.path
            }
        }

        showCopiedFeedback()
    }

    private func shareItem(item: ClipboardItem) {
        var shareItems: [Any] = []

        switch item.content {
        case let .text(text):
            shareItems.append(text)

        case let .image(data, _, _):
            if let image = UIImage(data: Data(data)) {
                shareItems.append(image)
            }

        case let .color(colorString):
            shareItems.append(colorString)

        case let .link(url, _):
            if let url = URL(string: url) {
                shareItems.append(url)
            }

        case let .file(_, entries):
            for entry in entries {
                shareItems.append(entry.path)
            }
        }

        guard !shareItems.isEmpty else { return }

        let activityVC = UIActivityViewController(
            activityItems: shareItems,
            applicationActivities: nil
        )

        if let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
            let rootVC = windowScene.windows.first?.rootViewController
        {
            // Find topmost presented controller
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = topVC.view
                popover.sourceRect = CGRect(
                    x: topVC.view.bounds.midX,
                    y: topVC.view.bounds.midY,
                    width: 0,
                    height: 0
                )
            }
            topVC.present(activityVC, animated: true)
        }
    }

    private func showCopiedFeedback() {
        withAnimation {
            copiedFeedback = true
        }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation {
                copiedFeedback = false
            }
        }
    }

    // MARK: - Helpers

    private func contentTitle(item: ClipboardItem) -> String {
        switch item.content {
        case .text: return "Text"
        case .image: return "Image"
        case .color: return "Color"
        case .link: return "Link"
        case .file: return "File"
        }
    }

    private func parseColor(_ colorString: String) -> Color {
        guard let c = FormattingHelpers.parseHexColor(colorString) else { return .gray }
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }
}
