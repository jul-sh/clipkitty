import Foundation

public enum NudgeKind: Equatable {
    case launchAtLogin
}

public enum InfoKind: Equatable {
    case rebuildingIndex
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
