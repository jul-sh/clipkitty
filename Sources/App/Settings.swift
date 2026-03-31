import AppKit
import Carbon
@preconcurrency import CoreGraphics
import Foundation
#if SPARKLE_RELEASE
    import SparkleUpdater
#endif

struct HotKey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let `default` = HotKey(keyCode: 49, modifiers: UInt32(optionKey)) // Option+Space

    private static let keyCodeNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
        38: "J", 40: "K", 45: "N", 46: "M",
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete",
        53: "Escape", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    /// Menu key equivalent strings (lowercase single char, or special char)
    private static let keyCodeEquivalents: [UInt32: String] = [
        49: " ", 36: "\r", 48: "\t",
    ]

    var displayString: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(Self.keyCodeNames[keyCode] ?? "Key\(keyCode)")
        return parts.joined()
    }

    /// Key equivalent string for NSMenuItem
    var keyEquivalent: String {
        if let special = Self.keyCodeEquivalents[keyCode] { return special }
        return Self.keyCodeNames[keyCode]?.lowercased() ?? ""
    }

    /// Modifier mask for NSMenuItem
    var modifierMask: NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        return mask
    }
}

enum PasteMode {
    case noPermission
    case copyOnly
    case autoPaste

    var buttonLabel: String {
        switch self {
        case .noPermission, .copyOnly:
            return String(localized: "Copy")
        case .autoPaste:
            return String(localized: "Paste")
        }
    }

    var editConfirmLabel: String {
        switch self {
        case .noPermission, .copyOnly:
            return String(localized: "Save & Copy")
        case .autoPaste:
            return String(localized: "Save & Paste")
        }
    }
}

#if SPARKLE_RELEASE
    /// State of update checking
    enum UpdateCheckState: String, Codable, Equatable {
        case idle
        case checking
        case downloading
        case installing
        case available
        case checkFailed
    }
#endif

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Shared permission monitor for reactive UI updates
    let accessibilityPermissionMonitor = AccessibilityPermissionMonitor()

    @Published var hotKey: HotKey {
        didSet { save() }
    }

    @Published var maxDatabaseSizeGB: Double {
        didSet { save() }
    }

    #if !APP_STORE
        /// Check if the app can post synthetic keyboard events (e.g. Cmd+V for direct paste)
        /// Uses the permission monitor for reactive updates.
        var hasPostEventPermission: Bool {
            return accessibilityPermissionMonitor.isGranted
        }

        /// Request permission to post synthetic keyboard events.
        /// Opens System Settings if not yet granted.
        /// Returns true if permissions are already granted.
        @discardableResult
        func requestPostEventPermission() -> Bool {
            return accessibilityPermissionMonitor.requestPermission()
        }

        /// User's selection for paste behavior: true = paste to active app, false = copy to clipboard
        /// This persists the user's *intent* regardless of permission state.
        @Published var autoPasteEnabled: Bool {
            didSet { save() }
        }

        /// The effective paste mode based on user preference AND permission state.
        /// - Returns `.autoPaste` only when user has enabled it AND permission is granted
        /// - Returns `.copyOnly` when user explicitly chose copy-only mode
        /// - Returns `.noPermission` when user wants autoPaste but permission is not granted
        var pasteMode: PasteMode {
            guard autoPasteEnabled else { return .copyOnly }
            guard hasPostEventPermission else { return .noPermission }
            return .autoPaste
        }
    #else
        var pasteMode: PasteMode {
            .copyOnly
        }
    #endif

    #if SPARKLE_RELEASE
        @Published var updateCheckState: UpdateCheckState = .idle
        @Published var lastUpdateCheckDate: Date? {
            didSet { save() }
        }
        @Published var lastUpdateCheckResult: UpdateCheckState = .idle {
            didSet { save() }
        }
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

    // MARK: - Privacy Settings

    /// Whether to ignore confidential/sensitive content (passwords from password managers)
    @Published var ignoreConfidentialContent: Bool {
        didSet { save() }
    }

    /// Whether to ignore transient content (temporary data from apps)
    @Published var ignoreTransientContent: Bool {
        didSet { save() }
    }

    /// Whether to generate link previews by fetching web content
    @Published var generateLinkPreviews: Bool {
        didSet { save() }
    }

    /// Whether the launch-at-login prompt has been dismissed (one-shot)
    @Published var launchAtLoginPromptDismissed: Bool {
        didSet { save() }
    }

    /// When the last info snackbar was dismissed (cooldown before showing nudges)
    @Published var lastInfoDismissDate: Date? {
        didSet { save() }
    }

    /// When the user last interacted with a nudge snackbar (cooldown before next nudge)
    @Published var lastNudgeInteractionDate: Date? {
        didSet { save() }
    }

    /// Whether the user has completed the first-launch onboarding
    @Published var hasCompletedOnboarding: Bool {
        didSet { save() }
    }

    /// The date the app was first launched (for time-gating the launch-at-login prompt)
    let firstLaunchDate: Date

    #if ENABLE_SYNC
        /// Whether iCloud sync is enabled
        @Published var syncEnabled: Bool {
            didSet { save() }
        }
    #endif

    /// Scale factor for browser text and panel dimensions (1.0 = default)
    @Published var textScale: CGFloat {
        didSet { save() }
    }

    /// Bundle IDs of apps whose clipboard content should be ignored
    @Published var ignoredAppBundleIds: Set<String> {
        didSet { save() }
    }

    private let defaults = UserDefaults.standard
    private let hotKeyKey = "hotKey"
    private let maxDbSizeKey = "maxDatabaseSizeGB"
    private let launchAtLoginKey = "launchAtLogin"
    #if !APP_STORE
        private let autoPasteKey = "autoPasteEnabled"
    #endif
    private let ignoreConfidentialKey = "ignoreConfidentialContent"
    private let ignoreTransientKey = "ignoreTransientContent"
    private let generateLinkPreviewsKey = "generateLinkPreviews"
    private let launchAtLoginPromptDismissedKey = "launchAtLoginPromptDismissed"
    private let hasCompletedOnboardingKey = "hasCompletedOnboarding"
    private let firstLaunchDateKey = "firstLaunchDate"
    private let lastInfoDismissDateKey = "lastInfoDismissDate"
    private let lastNudgeInteractionDateKey = "lastNudgeInteractionDate"
    #if ENABLE_SYNC
        private let syncEnabledKey = "syncEnabled"
    #endif
    private let textScaleKey = "textScale"
    private let ignoredAppBundleIdsKey = "ignoredAppBundleIds"
    #if SPARKLE_RELEASE
        private let autoInstallUpdatesKey = "autoInstallUpdates"
        private let updateChannelKey = "updateChannel"
        private let lastUpdateCheckDateKey = "lastUpdateCheckDate"
        private let lastUpdateCheckResultKey = "lastUpdateCheckResult"
    #endif

    /// Flag to prevent save() calls during initialization (didSet triggers before init completes)
    private var isInitializing = true

    private init() {
        // Initialize all stored properties first
        if let data = defaults.data(forKey: hotKeyKey),
           let decoded = try? JSONDecoder().decode(HotKey.self, from: data)
        {
            hotKey = decoded
        } else {
            hotKey = .default
        }

        if let stored = defaults.object(forKey: maxDbSizeKey) as? NSNumber {
            maxDatabaseSizeGB = stored.doubleValue
        } else {
            maxDatabaseSizeGB = 7.0
        }

        launchAtLoginEnabled = defaults.bool(forKey: launchAtLoginKey)
        #if !APP_STORE
            autoPasteEnabled = defaults.object(forKey: autoPasteKey) as? Bool ?? true
        #endif
        #if SPARKLE_RELEASE
            autoInstallUpdates = defaults.object(forKey: autoInstallUpdatesKey) as? Bool ?? true
            let storedUpdateChannel = defaults.string(forKey: updateChannelKey)
            updateChannel = storedUpdateChannel.flatMap(UpdateChannel.init(rawValue:)) ?? .stable
            lastUpdateCheckDate = defaults.object(forKey: lastUpdateCheckDateKey) as? Date
            let storedResult = defaults.string(forKey: lastUpdateCheckResultKey)
            lastUpdateCheckResult = storedResult.flatMap(UpdateCheckState.init(rawValue:)) ?? .idle
        #endif

        launchAtLoginPromptDismissed = defaults.bool(forKey: launchAtLoginPromptDismissedKey)
        lastInfoDismissDate = defaults.object(forKey: lastInfoDismissDateKey) as? Date
        lastNudgeInteractionDate = defaults.object(forKey: lastNudgeInteractionDateKey) as? Date
        hasCompletedOnboarding = defaults.bool(forKey: hasCompletedOnboardingKey)

        if let stored = defaults.object(forKey: firstLaunchDateKey) as? Date {
            firstLaunchDate = stored
        } else {
            firstLaunchDate = Date()
            defaults.set(firstLaunchDate, forKey: firstLaunchDateKey)
        }

        // Sync - default to disabled (user opts in via Settings)
        #if ENABLE_SYNC
            syncEnabled = defaults.object(forKey: syncEnabledKey) as? Bool ?? false
        #endif

        // Privacy settings - default to enabled for user protection
        ignoreConfidentialContent = defaults.object(forKey: ignoreConfidentialKey) as? Bool ?? true
        ignoreTransientContent = defaults.object(forKey: ignoreTransientKey) as? Bool ?? true
        generateLinkPreviews = defaults.object(forKey: generateLinkPreviewsKey) as? Bool ?? true

        // Text scale
        if let stored = defaults.object(forKey: textScaleKey) as? Double {
            textScale = CGFloat(stored)
        } else {
            textScale = 1.0
        }

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
        if let data = try? JSONEncoder().encode(hotKey) {
            defaults.set(data, forKey: hotKeyKey)
        }
        defaults.set(maxDatabaseSizeGB, forKey: maxDbSizeKey)
        defaults.set(launchAtLoginEnabled, forKey: launchAtLoginKey)
        #if !APP_STORE
            defaults.set(autoPasteEnabled, forKey: autoPasteKey)
        #endif
        defaults.set(launchAtLoginPromptDismissed, forKey: launchAtLoginPromptDismissedKey)
        defaults.set(lastInfoDismissDate, forKey: lastInfoDismissDateKey)
        defaults.set(lastNudgeInteractionDate, forKey: lastNudgeInteractionDateKey)
        defaults.set(hasCompletedOnboarding, forKey: hasCompletedOnboardingKey)
        #if ENABLE_SYNC
            defaults.set(syncEnabled, forKey: syncEnabledKey)
        #endif
        defaults.set(ignoreConfidentialContent, forKey: ignoreConfidentialKey)
        defaults.set(ignoreTransientContent, forKey: ignoreTransientKey)
        defaults.set(generateLinkPreviews, forKey: generateLinkPreviewsKey)
        defaults.set(Double(textScale), forKey: textScaleKey)
        defaults.set(Array(ignoredAppBundleIds).sorted(), forKey: ignoredAppBundleIdsKey)
        #if SPARKLE_RELEASE
            defaults.set(autoInstallUpdates, forKey: autoInstallUpdatesKey)
            defaults.set(updateChannel.rawValue, forKey: updateChannelKey)
            defaults.set(lastUpdateCheckDate, forKey: lastUpdateCheckDateKey)
            defaults.set(lastUpdateCheckResult.rawValue, forKey: lastUpdateCheckResultKey)
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

    /// Returns the given size multiplied by the current text scale factor.
    func scaled(_ size: CGFloat) -> CGFloat {
        size * textScale
    }
}
