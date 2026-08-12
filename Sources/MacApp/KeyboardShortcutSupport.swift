import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Shortcut {
    static let defaultShowClipboardHistory = Self(.space, modifiers: [.option])
    static let defaultDeleteSelectedItem = Self(.minus, modifiers: [.command])

    static let browserBookmark = Self(.b, modifiers: [.command])
    static let browserCopyOnly = Self(.c, modifiers: [.command])
    static let browserDefaultAction = Self(.return)
    static let browserDeleteFallback = Self(.delete)

    static let reservedBrowserActionShortcuts: Set<Self> = [
        .browserBookmark,
        .browserCopyOnly,
        .browserDefaultAction,
    ]
}

extension KeyboardShortcuts.Name {
    static let showClipboardHistory = Self(
        "showClipboardHistory",
        initial: .defaultShowClipboardHistory
    )
}

func shortcutConflictReason(for actionName: String) -> String {
    String.localizedStringWithFormat(
        String(localized: "This shortcut is already used by %@."),
        actionName
    )
}

/// The panel-only shortcut has an explicit disabled state because binding-based
/// KeyboardShortcuts recorders intentionally leave persistence to the app.
/// Modeling that state directly prevents a cleared shortcut from silently
/// reverting to its default on the next launch.
enum DeleteItemShortcutSetting: Codable, Equatable {
    case enabled(KeyboardShortcuts.Shortcut)
    case disabled

    var browserShortcut: KeyboardShortcuts.Shortcut {
        switch self {
        case let .enabled(shortcut) where !KeyboardShortcuts.Shortcut.reservedBrowserActionShortcuts.contains(shortcut):
            return shortcut
        case .enabled, .disabled:
            return .browserDeleteFallback
        }
    }
}
