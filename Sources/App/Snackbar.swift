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
    case rebuildingIndex
}

enum NotificationKind: Equatable {
    case passive(message: String, iconSystemName: String)
    case actionable(message: String, iconSystemName: String, actionTitle: String)

    var message: String {
        switch self {
        case let .passive(message, _), let .actionable(message, _, _):
            return message
        }
    }

    var iconSystemName: String {
        switch self {
        case let .passive(_, icon), let .actionable(_, icon, _):
            return icon
        }
    }

    var duration: TimeInterval {
        switch self {
        case let .passive(message, _):
            let baseDuration = 2.0
            let extraChars = max(0, message.count - 10)
            let extraTime = Double(extraChars / 10) * 0.5
            return min(baseDuration + extraTime, 4.5)
        case .actionable:
            return 4.0
        }
    }
}

enum SnackbarItem: Equatable {
    case nudge(NudgeKind)
    case info(InfoKind)
    case notification(NotificationKind)
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
        case .info(.rebuildingIndex):
            RebuildingIndexInfoView()
        case let .notification(kind):
            NotificationSnackbarView(kind: kind, onAction: onAction)
        }
    }
}

private struct NotificationSnackbarView: View {
    let kind: NotificationKind
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: kind.iconSystemName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)

            Text(kind.message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)

            if case let .actionable(_, _, actionTitle) = kind {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.leading, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .fixedSize()
        .modifier(GlassBackgroundModifier())
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
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)

            Text("Rebuilding index…", comment: "Snackbar message shown during index rebuild")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .fixedSize()
        .modifier(GlassBackgroundModifier())
    }
}
