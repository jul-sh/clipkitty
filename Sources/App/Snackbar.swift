import SwiftUI

// MARK: - Shared background modifier

struct GlassBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
        }
    }
}

// MARK: - Snackbar types

enum NudgeKind: Equatable {
    case launchAtLogin
}

enum InfoKind: Equatable {
    case rebuildingIndex(progress: Double)
}

enum SnackbarItem: Equatable {
    case nudge(NudgeKind)
    case info(InfoKind)
}

// MARK: - Snackbar views

struct SnackbarView: View {
    let item: SnackbarItem
    let onAction: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        switch item {
        case .nudge(.launchAtLogin):
            LaunchAtLoginNudgeView(onEnable: onAction, onDismiss: onDismiss)
        case let .info(.rebuildingIndex(progress)):
            RebuildingIndexInfoView(progress: progress)
        }
    }
}

private struct LaunchAtLoginNudgeView: View {
    let onEnable: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sunrise.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.orange)

            Text("Launch at Login")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)

            Button("Enable") {
                onEnable()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.leading, 4)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .fixedSize()
        .modifier(GlassBackgroundModifier())
    }
}

private struct RebuildingIndexInfoView: View {
    let progress: Double

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)

            Text("Rebuilding index\(progress < 1.0 ? " \(Int(progress * 100))%" : "…")")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .fixedSize()
        .modifier(GlassBackgroundModifier())
    }
}
