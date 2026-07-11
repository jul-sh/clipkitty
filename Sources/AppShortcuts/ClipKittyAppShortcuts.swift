#if ENABLE_APP_SHORTCUTS
    import AppIntents
    import ClipKittyShortcuts

    /// The App Shortcuts surfaced in the Shortcuts app, Siri, and Spotlight.
    ///
    /// This lives in the app targets (not ClipKittyShortcuts) because the
    /// system only registers App Shortcuts whose provider is compiled into
    /// the app bundle itself: appintentsmetadataprocessor does not merge
    /// `autoShortcuts` metadata from statically linked dependencies, so a
    /// provider defined in the library produces an app with intents but no
    /// App Shortcuts. The intents it references stay in ClipKittyShortcuts;
    /// their metadata merges into the app at build time. Do not add an
    /// `AppIntentsPackage`/`includedPackages` declaration for the library:
    /// linkd resolves package references against the executable's imported
    /// symbols, which fails for a statically linked package and aborts App
    /// Shortcuts registration at install time.
    public struct ClipKittyAppShortcuts: AppShortcutsProvider {
        public static var shortcutTileColor: ShortcutTileColor {
            .pink
        }

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
#endif
