import Foundation

public enum NudgeKind: Equatable {
    case launchAtLogin
}

/// An ongoing status shown in the snackbar slot. Unlike `NotificationKind`,
/// these don't auto-dismiss; they're driven by underlying state and stay until
/// the state clears. Each platform maps its own state sources (index rebuild,
/// sync activity, etc.) into one of these cases.
public enum InfoKind: Equatable {
    case rebuildingIndex
    case catchingUpWithCloud
    case syncingCloudChanges(count: Int)

    public var message: String {
        switch self {
        case .rebuildingIndex:
            return String(localized: "Rebuilding index…")
        case .catchingUpWithCloud:
            return String(localized: "Catching up with iCloud")
        case let .syncingCloudChanges(count):
            return String(localized: "Syncing \(count) changes from iCloud")
        }
    }

    /// SF Symbol for the leading icon, or `nil` when the snackbar should show a
    /// progress spinner instead of an icon (matches the Mac "Rebuilding index"
    /// presentation).
    public var iconSystemName: String? {
        switch self {
        case .rebuildingIndex:
            return nil
        case .catchingUpWithCloud, .syncingCloudChanges:
            return "icloud.and.arrow.down"
        }
    }
}

public enum NotificationKind: Equatable {
    case passive(message: String, iconSystemName: String)
    case actionable(message: String, iconSystemName: String, actionTitle: String)

    public var message: String {
        switch self {
        case let .passive(message, _), let .actionable(message, _, _):
            return message
        }
    }

    public var iconSystemName: String {
        switch self {
        case let .passive(_, icon), let .actionable(_, icon, _):
            return icon
        }
    }

    public var duration: TimeInterval {
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

public enum SnackbarItem: Equatable {
    case nudge(NudgeKind)
    case info(InfoKind)
    case notification(NotificationKind)
}
