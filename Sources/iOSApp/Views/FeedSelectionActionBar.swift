import SwiftUI

/// Bottom actions shown while the history feed is in explicit selection mode.
struct FeedSelectionActionBar: View {
    let selectedItemIDs: [String]
    /// Whether every selected item already carries the bookmark tag. Drives
    /// the pin button's icon and toggle direction: bookmarking a mixed
    /// selection bookmarks the rest, so only a fully-bookmarked selection
    /// offers to remove it.
    let allSelectedAreBookmarked: Bool
    let isCopying: Bool
    let onCopy: () -> Void
    let onToggleBookmark: () -> Void
    let onShare: () -> Void
    let onDelete: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 0) {
                copyAction

                actionButton(
                    title: allSelectedAreBookmarked
                        ? String(localized: "Remove Bookmark")
                        : String(localized: "Bookmark"),
                    systemImage: allSelectedAreBookmarked ? "bookmark.slash" : "bookmark",
                    isEnabled: !selectedItemIDs.isEmpty,
                    identifier: "selection.bookmarkButton",
                    action: onToggleBookmark
                )

                actionButton(
                    title: String(localized: "Share"),
                    systemImage: "square.and.arrow.up",
                    isEnabled: !selectedItemIDs.isEmpty,
                    identifier: "selection.shareButton",
                    action: onShare
                )

                actionButton(
                    title: String(localized: "Delete"),
                    systemImage: "trash",
                    role: .destructive,
                    isEnabled: !selectedItemIDs.isEmpty,
                    identifier: "selection.deleteButton",
                    action: onDelete
                )
                .foregroundStyle(.red)
            }
            .padding(.horizontal, 8)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var copyAction: some View {
        Button(action: onCopy) {
            Group {
                if isCopying {
                    ProgressView()
                } else {
                    Image(systemName: "doc.on.doc")
                        .font(.body.weight(.medium))
                }
            }
            .frame(width: 52, height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(selectedItemIDs.isEmpty || isCopying)
        .accessibilityLabel(String(localized: "Copy"))
        .accessibilityIdentifier("selection.copyButton")
    }

    private func actionButton(
        title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        isEnabled: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}
