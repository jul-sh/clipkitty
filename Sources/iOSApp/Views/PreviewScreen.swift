import SwiftUI

/// Compact-only pushed detail view. Wraps `DetailPane` with dismiss capability.
struct PreviewScreen: View {
    let itemId: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DetailPane(
            itemId: itemId,
            onDelete: { dismiss() }
        )
    }
}
