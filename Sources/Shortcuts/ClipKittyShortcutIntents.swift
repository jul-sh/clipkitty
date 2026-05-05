import AppIntents
import Foundation

public struct ClipKittyShortcutsPackage: AppIntentsPackage {
    public init() {}
}

public struct SaveTextToClipKittyIntent: AppIntent {
    public static var title: LocalizedStringResource = "Save Text to ClipKitty"
    public static var description: IntentDescription? = "Save text into ClipKitty's clipboard history."
    public static var openAppWhenRun = false

    @Parameter(title: "Text")
    public var text: String

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let saved = try await ClipKittyShortcutRuntime.makeService().saveText(text)
        return .result(value: text, dialog: ShortcutIntentResult.dialog(for: saved))
    }
}

public struct SaveClipboardToClipKittyIntent: AppIntent {
    public static var title: LocalizedStringResource = "Save Clipboard to ClipKitty"
    public static var description: IntentDescription? = "Save the current text or image clipboard item into ClipKitty."
    public static var openAppWhenRun = false

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let saved = try await ClipKittyShortcutRuntime.makeService().saveCurrentClipboard()
        return .result(
            value: ShortcutIntentResult.value(for: saved),
            dialog: ShortcutIntentResult.dialog(for: saved)
        )
    }
}

public struct SearchClipKittyTextIntent: AppIntent {
    public static var title: LocalizedStringResource = "Search ClipKitty Text"
    public static var description: IntentDescription? = "Search ClipKitty's text clipboard history."
    public static var openAppWhenRun = false

    @Parameter(title: "Query")
    public var query: String

    @Parameter(title: "Maximum Results", default: 5)
    public var limit: Int

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let values = try await ClipKittyShortcutRuntime.makeService().searchText(query: query, limit: limit)
        return .result(value: values)
    }
}

public struct GetRecentClipKittyTextIntent: AppIntent {
    public static var title: LocalizedStringResource = "Get Recent ClipKitty Text"
    public static var description: IntentDescription? = "Get recent text clips from ClipKitty."
    public static var openAppWhenRun = false

    @Parameter(title: "Maximum Results", default: 5)
    public var limit: Int

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let values = try await ClipKittyShortcutRuntime.makeService().fetchRecentText(limit: limit)
        return .result(value: values)
    }
}

public struct ClipKittyAppShortcuts: AppShortcutsProvider {
    public static var shortcutTileColor: ShortcutTileColor { .pink }

    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SaveTextToClipKittyIntent(),
            phrases: [
                "Save text to \(.applicationName)",
                "Add text to \(.applicationName)",
            ],
            shortTitle: "Save Text",
            systemImageName: "plus"
        )

        AppShortcut(
            intent: SaveClipboardToClipKittyIntent(),
            phrases: [
                "Save clipboard to \(.applicationName)",
                "Add clipboard to \(.applicationName)",
            ],
            shortTitle: "Save Clipboard",
            systemImageName: "clipboard"
        )

        AppShortcut(
            intent: SearchClipKittyTextIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Find text in \(.applicationName)",
            ],
            shortTitle: "Search Text",
            systemImageName: "magnifyingglass"
        )

        AppShortcut(
            intent: GetRecentClipKittyTextIntent(),
            phrases: [
                "Get recent text from \(.applicationName)",
                "Get recent clips from \(.applicationName)",
            ],
            shortTitle: "Recent Text",
            systemImageName: "clock"
        )
    }
}

private enum ShortcutIntentResult {
    static func dialog(for saved: ShortcutSavedClip) -> IntentDialog {
        switch saved {
        case .inserted:
            return "Saved to ClipKitty."
        case .duplicate:
            return "Already in ClipKitty."
        }
    }

    static func value(for saved: ShortcutSavedClip) -> String {
        switch saved {
        case let .inserted(id):
            return id
        case .duplicate:
            return "Already in ClipKitty"
        }
    }
}
