import SwiftUI

/// Bottom actions shown while the history feed is in explicit selection mode.
struct FeedSelectionActionBar: View {
    let selectedItemIDs: [String]
    let makeDragPayload: @MainActor ([String]) -> ExternalCopyDragPayload
    let isCopying: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onTransferLimitExceeded: () -> Void
    let onExternalCopyTransferCompleted: @MainActor ([ExternalCopyTransferEvidence]) async -> Void

    var body: some View {
        GlassEffectContainer(spacing: 20) {
            HStack(spacing: 20) {
                copyAction

                dragAction

                actionButton(
                    title: String(localized: "Delete"),
                    systemImage: "trash",
                    role: .destructive,
                    isEnabled: !selectedItemIDs.isEmpty,
                    action: onDelete
                )
            }
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
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(selectedItemIDs.isEmpty || isCopying)
        .accessibilityLabel(String(localized: "Copy"))
    }

    private func actionButton(
        title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .frame(width: 52, height: 52)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }

    private var dragAction: some View {
        ZStack {
            Image(systemName: "hand.draw")
                .font(.body.weight(.medium))
                .accessibilityHidden(true)

            ExternalCopyDragInteractionView(
                makePayload: makeSelectedDragPayload,
                onExternalCopyTransferCompleted: onExternalCopyTransferCompleted,
                accessibilityName: String(localized: "Drag Selected Items"),
                accessibilityHint: dragAccessibilityHint
            )
            .accessibilityHidden(selectedItemIDs.isEmpty || isCopying)
        }
        .frame(width: 52, height: 52)
        .contentShape(Circle())
        .glassEffect(.regular.interactive(), in: .circle)
        .opacity(selectedItemIDs.isEmpty || isCopying ? 0.45 : 1)
        .allowsHitTesting(!selectedItemIDs.isEmpty && !isCopying)
    }

    @MainActor
    private func makeSelectedDragPayload() -> ExternalCopyDragPayload {
        guard !exceedsTransferItemLimit else {
            onTransferLimitExceeded()
            return ExternalCopyDragPayload(items: [])
        }
        return makeDragPayload(selectedItemIDs)
    }

    private var exceedsTransferItemLimit: Bool {
        selectedItemIDs.count > iOSTransferLimits.maximumItemCount
    }

    private var dragAccessibilityHint: String {
        if exceedsTransferItemLimit {
            return String.localizedStringWithFormat(
                String(localized: "Select %lld or fewer items to drag."),
                Int64(iOSTransferLimits.maximumItemCount)
            )
        }
        return String(localized: "Drag the selected items into another app")
    }
}
