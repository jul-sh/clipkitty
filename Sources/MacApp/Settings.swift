import AppKit
import ClipKittyMacPlatform
import ClipKittyShared
@preconcurrency import CoreGraphics
import Foundation
#if ENABLE_SPARKLE_UPDATES
    import SparkleUpdater
#endif

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

#if ENABLE_SPARKLE_UPDATES
    /// State of update checking
    enum UpdateCheckState: Codable, Equatable {
        case idle
        case checking
        case downloading
        case installing
        case available
        case checkFailed(errorMessage: String)

        /// Tag used for Codable round-tripping
        private enum Tag: String, Codable {
            case idle, checking, downloading, installing, available, checkFailed
        }

        private enum CodingKeys: String, CodingKey {
            case tag, errorMessage
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(Tag.self, forKey: .tag)
            switch tag {
            case .idle: self = .idle
            case .checking: self = .checking
            case .downloading: self = .downloading
            case .installing: self = .installing
            case .available: self = .available
            case .checkFailed:
                let message = try container.decodeIfPresent(String.self, forKey: .errorMessage) ?? ""
                self = .checkFailed(errorMessage: message)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .idle: try container.encode(Tag.idle, forKey: .tag)
            case .checking: try container.encode(Tag.checking, forKey: .tag)
            case .downloading: try container.encode(Tag.downloading, forKey: .tag)
            case .installing: try container.encode(Tag.installing, forKey: .tag)
            case .available: try container.encode(Tag.available, forKey: .tag)
            case .checkFailed(let message):
                try container.encode(Tag.checkFailed, forKey: .tag)
                try container.encode(message, forKey: .errorMessage)
            }
        }
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

    #if ENABLE_SYNTHETIC_PASTE
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

    #if ENABLE_SPARKLE_UPDATES
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

    #if ENABLE_LINK_PREVIEWS
        /// Whether to generate link previews by fetching web content
        @Published var generateLinkPreviews: Bool {
            didSet { save() }
        }
    #endif

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

    #if ENABLE_ICLOUD_SYNC
        /// Whether iCloud sync is enabled
        @Published var syncEnabled: Bool {
            didSet { save() }
        }
    #endif

    /// Scale factor for browser text and panel dimensions, derived from system accessibility text size.
    /// Minimum is 1.0 (system default), maximum is capped at 1.5.
    @Published var textScale: CGFloat

    /// Bundle IDs of apps whose clipboard content should be ignored
    @Published var ignoredAppBundleIds: Set<String> {
        didSet { save() }
    }

    private let defaults = UserDefaults.standard
    private let hotKeyKey = "hotKey"
    private let maxDbSizeKey = "maxDatabaseSizeGB"
    private let launchAtLoginKey = "launchAtLogin"
    #if ENABLE_SYNTHETIC_PASTE
        private let autoPasteKey = "autoPasteEnabled"
    #endif
    private let ignoreConfidentialKey = "ignoreConfidentialContent"
    private let ignoreTransientKey = "ignoreTransientContent"
    #if ENABLE_LINK_PREVIEWS
        private let generateLinkPreviewsKey = "generateLinkPreviews"
    #endif
    private let launchAtLoginPromptDismissedKey = "launchAtLoginPromptDismissed"
    private let hasCompletedOnboardingKey = "hasCompletedOnboarding"
    private let firstLaunchDateKey = "firstLaunchDate"
    private let lastInfoDismissDateKey = "lastInfoDismissDate"
    private let lastNudgeInteractionDateKey = "lastNudgeInteractionDate"
    #if ENABLE_ICLOUD_SYNC
        private let syncEnabledKey = "syncEnabled"
    #endif
    private var textScaleObserver: Any?
    private let ignoredAppBundleIdsKey = "ignoredAppBundleIds"
    #if ENABLE_SPARKLE_UPDATES
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
        #if ENABLE_SYNTHETIC_PASTE
            autoPasteEnabled = defaults.object(forKey: autoPasteKey) as? Bool ?? false
        #endif
        #if ENABLE_SPARKLE_UPDATES
            autoInstallUpdates = defaults.object(forKey: autoInstallUpdatesKey) as? Bool ?? true
            let storedUpdateChannel = defaults.string(forKey: updateChannelKey)
            updateChannel = storedUpdateChannel.flatMap(UpdateChannel.init(rawValue:)) ?? .stable
            lastUpdateCheckDate = defaults.object(forKey: lastUpdateCheckDateKey) as? Date
            if let resultData = defaults.data(forKey: lastUpdateCheckResultKey),
               let decoded = try? JSONDecoder().decode(UpdateCheckState.self, from: resultData)
            {
                lastUpdateCheckResult = decoded
            } else {
                lastUpdateCheckResult = .idle
            }
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
        #if ENABLE_ICLOUD_SYNC
            syncEnabled = defaults.object(forKey: syncEnabledKey) as? Bool ?? false
        #endif

        // Privacy settings - default to enabled for user protection
        ignoreConfidentialContent = defaults.object(forKey: ignoreConfidentialKey) as? Bool ?? true
        ignoreTransientContent = defaults.object(forKey: ignoreTransientKey) as? Bool ?? true
        #if ENABLE_LINK_PREVIEWS
            generateLinkPreviews = defaults.object(forKey: generateLinkPreviewsKey) as? Bool ?? true
        #endif

        // Text scale from system accessibility setting
        textScale = Self.systemTextScale()

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

        // Observe system text size changes (Accessibility > Display > Text Size)
        textScaleObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSPreferredContentSizeCategoryDidChangeNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.textScale = Self.systemTextScale()
            }
        }
    }

    /// Maps system accessibility text size to a scale factor (1.0–1.5)
    private static func systemTextScale() -> CGFloat {
        let category = UserDefaults.standard.string(forKey: "UIPreferredContentSizeCategoryName")
            ?? "UICTContentSizeCategoryL"
        // Scale proportionally to iOS body font sizes (baseline: L = 17pt, cap: a11y L = 33pt)
        let scale: CGFloat = switch category {
        case "UICTContentSizeCategoryXS", "UICTContentSizeCategoryS",
             "UICTContentSizeCategoryM", "UICTContentSizeCategoryL":
            1.0
        case "UICTContentSizeCategoryXL":
            1.12  // 19/17
        case "UICTContentSizeCategoryXXL":
            1.24  // 21/17
        case "UICTContentSizeCategoryXXXL":
            1.35  // 23/17
        default:
            1.5   // a11y M and above
        }
        return min(scale, 1.5)
    }

    private func save() {
        // Prevent save during init (didSet fires before init completes)
        guard !isInitializing else { return }
        if let data = try? JSONEncoder().encode(hotKey) {
            defaults.set(data, forKey: hotKeyKey)
        }
        defaults.set(maxDatabaseSizeGB, forKey: maxDbSizeKey)
        defaults.set(launchAtLoginEnabled, forKey: launchAtLoginKey)
        #if ENABLE_SYNTHETIC_PASTE
            defaults.set(autoPasteEnabled, forKey: autoPasteKey)
        #endif
        defaults.set(launchAtLoginPromptDismissed, forKey: launchAtLoginPromptDismissedKey)
        defaults.set(lastInfoDismissDate, forKey: lastInfoDismissDateKey)
        defaults.set(lastNudgeInteractionDate, forKey: lastNudgeInteractionDateKey)
        defaults.set(hasCompletedOnboarding, forKey: hasCompletedOnboardingKey)
        #if ENABLE_ICLOUD_SYNC
            defaults.set(syncEnabled, forKey: syncEnabledKey)
        #endif
        defaults.set(ignoreConfidentialContent, forKey: ignoreConfidentialKey)
        defaults.set(ignoreTransientContent, forKey: ignoreTransientKey)
        #if ENABLE_LINK_PREVIEWS
            defaults.set(generateLinkPreviews, forKey: generateLinkPreviewsKey)
        #endif
        // textScale is derived from system accessibility setting, not persisted
        defaults.set(Array(ignoredAppBundleIds).sorted(), forKey: ignoredAppBundleIdsKey)
        #if ENABLE_SPARKLE_UPDATES
            defaults.set(autoInstallUpdates, forKey: autoInstallUpdatesKey)
            defaults.set(updateChannel.rawValue, forKey: updateChannelKey)
            defaults.set(lastUpdateCheckDate, forKey: lastUpdateCheckDateKey)
            if let resultData = try? JSONEncoder().encode(lastUpdateCheckResult) {
                defaults.set(resultData, forKey: lastUpdateCheckResultKey)
            }
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
