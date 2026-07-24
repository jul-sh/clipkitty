import ClipKittyCore
import Foundation
import KeyboardShortcuts
#if ENABLE_SPARKLE_UPDATES
    import SparkleUpdater
#endif

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var deleteItemShortcutSetting: DeleteItemShortcutSetting {
        didSet { save() }
    }

    @Published var maxDatabaseSizeGB: Double {
        didSet { save() }
    }

    #if ENABLE_SYNTHETIC_PASTE
        /// User's selection for paste behavior: true = paste to active app, false = copy to clipboard
        /// This persists the user's *intent* regardless of permission state.
        @Published var autoPasteEnabled: Bool {
            didSet { save() }
        }
    #endif

    #if ENABLE_SPARKLE_UPDATES
        @Published var autoInstallUpdates: Bool {
            didSet { save() }
        }

        @Published var updateChannel: UpdateChannel {
            didSet { save() }
        }
    #endif

    let maxImageMegapixels: Double
    let imageCompressionQuality: Double

    @Published var launchAtLoginEnabled: Bool {
        didSet { save() }
    }

    @Published var fontPreference: AppFontPreference {
        didSet { save() }
    }

    @Published var previewFontPreference: PreviewFontPreference {
        didSet { save() }
    }

    // MARK: - Privacy Settings

    /// Whether to ignore confidential/sensitive content (passwords from password managers)
    @Published var ignoreConfidentialContent: Bool {
        didSet { save() }
    }

    /// Whether to ignore transient content (temporary data from apps)
    @Published var ignoreTransientContent: Bool {
        didSet { save() }
    }

    #if ENABLE_LINK_PREVIEWS
        /// Whether to generate link previews by fetching web content
        @Published var generateLinkPreviews: Bool {
            didSet { save() }
        }
    #endif

    #if ENABLE_ICLOUD_SYNC
        /// Whether iCloud sync is enabled
        @Published var syncEnabled: Bool {
            didSet { save() }
        }
    #endif

    /// Bundle IDs of apps whose clipboard content should be ignored
    @Published var ignoredAppBundleIds: Set<String> {
        didSet { save() }
    }

    private let defaults = UserDefaults.standard
    private let maxDbSizeKey = "maxDatabaseSizeGB"
    private let deleteItemShortcutKey = "deleteSelectedItemShortcut"
    private let launchAtLoginKey = "launchAtLogin"
    private let fontPreferenceKey = "fontPreference"
    private let previewFontPreferenceKey = "previewFontPreference"
    #if ENABLE_SYNTHETIC_PASTE
        private let autoPasteKey = "autoPasteEnabled"
    #endif
    private let ignoreConfidentialKey = "ignoreConfidentialContent"
    private let ignoreTransientKey = "ignoreTransientContent"
    #if ENABLE_LINK_PREVIEWS
        private let generateLinkPreviewsKey = "generateLinkPreviews"
    #endif
    #if ENABLE_ICLOUD_SYNC
        private let syncEnabledKey = "syncEnabled"
    #endif
    private let ignoredAppBundleIdsKey = "ignoredAppBundleIds"
    #if ENABLE_SPARKLE_UPDATES
        private let autoInstallUpdatesKey = "autoInstallUpdates"
        private let updateChannelKey = "updateChannel"
    #endif

    /// Flag to prevent save() calls during initialization (didSet triggers before init completes)
    private var isInitializing = true

    private init() {
        // Initialize all stored properties first
        if let data = defaults.data(forKey: deleteItemShortcutKey),
           let decoded = try? JSONDecoder().decode(DeleteItemShortcutSetting.self, from: data)
        {
            deleteItemShortcutSetting = decoded
        } else {
            deleteItemShortcutSetting = .enabled(.defaultDeleteSelectedItem)
        }

        if let stored = defaults.object(forKey: maxDbSizeKey) as? NSNumber {
            maxDatabaseSizeGB = stored.doubleValue
        } else {
            maxDatabaseSizeGB = 7.0
        }

        launchAtLoginEnabled = defaults.bool(forKey: launchAtLoginKey)
        fontPreference = defaults.string(forKey: fontPreferenceKey)
            .flatMap(AppFontPreference.init(rawValue:)) ?? .system
        previewFontPreference = defaults.string(forKey: previewFontPreferenceKey)
            .flatMap(PreviewFontPreference.init(rawValue:)) ?? .coding
        #if ENABLE_SYNTHETIC_PASTE
            autoPasteEnabled = defaults.object(forKey: autoPasteKey) as? Bool ?? false
        #endif
        #if ENABLE_SPARKLE_UPDATES
            autoInstallUpdates = defaults.object(forKey: autoInstallUpdatesKey) as? Bool ?? true
            let storedUpdateChannel = defaults.string(forKey: updateChannelKey)
            updateChannel = storedUpdateChannel.flatMap(UpdateChannel.init(rawValue:)) ?? .stable
        #endif

        // Sync - default to disabled (user opts in via Settings)
        #if ENABLE_ICLOUD_SYNC
            syncEnabled = defaults.object(forKey: syncEnabledKey) as? Bool ?? false
        #endif

        // Privacy settings - default to enabled for user protection
        ignoreConfidentialContent = defaults.object(forKey: ignoreConfidentialKey) as? Bool ?? true
        ignoreTransientContent = defaults.object(forKey: ignoreTransientKey) as? Bool ?? true
        #if ENABLE_LINK_PREVIEWS
            generateLinkPreviews = defaults.object(forKey: generateLinkPreviewsKey) as? Bool ?? true
        #endif

        // Load ignored app bundle IDs
        if let storedIds = defaults.stringArray(forKey: ignoredAppBundleIdsKey) {
            ignoredAppBundleIds = Set(storedIds)
        } else {
            // Default ignored apps: Keychain Access and Passwords
            ignoredAppBundleIds = [
                "com.apple.keychainaccess",
                "com.apple.Passwords",
            ]
        }

        maxImageMegapixels = 2.0
        imageCompressionQuality = 0.3

        // Mark initialization complete - save() calls are now allowed
        isInitializing = false
    }

    private func save() {
        // Prevent save during init (didSet fires before init completes)
        guard !isInitializing else { return }
        if let data = try? JSONEncoder().encode(deleteItemShortcutSetting) {
            defaults.set(data, forKey: deleteItemShortcutKey)
        }
        defaults.set(maxDatabaseSizeGB, forKey: maxDbSizeKey)
        defaults.set(launchAtLoginEnabled, forKey: launchAtLoginKey)
        defaults.set(fontPreference.rawValue, forKey: fontPreferenceKey)
        defaults.set(previewFontPreference.rawValue, forKey: previewFontPreferenceKey)
        #if ENABLE_SYNTHETIC_PASTE
            defaults.set(autoPasteEnabled, forKey: autoPasteKey)
        #endif
        #if ENABLE_ICLOUD_SYNC
            defaults.set(syncEnabled, forKey: syncEnabledKey)
        #endif
        defaults.set(ignoreConfidentialContent, forKey: ignoreConfidentialKey)
        defaults.set(ignoreTransientContent, forKey: ignoreTransientKey)
        #if ENABLE_LINK_PREVIEWS
            defaults.set(generateLinkPreviews, forKey: generateLinkPreviewsKey)
        #endif
        defaults.set(Array(ignoredAppBundleIds).sorted(), forKey: ignoredAppBundleIdsKey)
        #if ENABLE_SPARKLE_UPDATES
            defaults.set(autoInstallUpdates, forKey: autoInstallUpdatesKey)
            defaults.set(updateChannel.rawValue, forKey: updateChannelKey)
        #endif
    }

    // MARK: - Ignored Apps Management

    func addIgnoredApp(bundleId: String) {
        ignoredAppBundleIds.insert(bundleId)
    }

    func removeIgnoredApp(bundleId: String) {
        ignoredAppBundleIds.remove(bundleId)
    }

    func isAppIgnored(bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return ignoredAppBundleIds.contains(bundleId)
    }
}
