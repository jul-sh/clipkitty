import ClipKittyShared
import SwiftUI

// MARK: - Shared background modifier

struct GlassBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.thickMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
        }
    }
}

/// Glass capsule shared by every Mac snackbar variant, so they all agree on
/// shape, spacing, and type size; the iOS equivalent lives in RootView.swift.
private struct SnackbarCapsule<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .fixedSize()
        .modifier(GlassBackgroundModifier())
    }
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
        case let .info(kind):
            InfoSnackbarView(kind: kind)
        case let .notification(kind):
            NotificationSnackbarView(kind: kind, onAction: onAction)
        }
    }
}

private struct NotificationSnackbarView: View {
    let kind: NotificationKind
    let onAction: () -> Void

    var body: some View {
        SnackbarCapsule {
            Image(systemName: kind.iconSystemName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)

            Text(kind.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)

            if case let .actionable(_, _, actionTitle) = kind {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.leading, 8)
            }
        }
    }
}

private struct LaunchAtLoginNudgeView: View {
    let onEnable: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        SnackbarCapsule {
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
    }
}

private struct InfoSnackbarView: View {
    let kind: InfoKind

    var body: some View {
        SnackbarCapsule {
            if let icon = kind.iconSystemName {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            Text(kind.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
    }
}
