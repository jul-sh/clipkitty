import AppIntents

struct ClipKittyShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchClipboardIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Find in \(.applicationName)",
                "Search clipboard in \(.applicationName)",
            ],
            shortTitle: "Search Clipboard",
            systemImageName: "magnifyingglass"
        )

        AppShortcut(
            intent: AddClipboardItemIntent(),
            phrases: [
                "Add to \(.applicationName)",
                "Save to \(.applicationName)",
                "Add text to \(.applicationName)",
            ],
            shortTitle: "Add to Clipboard",
            systemImageName: "plus.circle"
        )
    }
}
