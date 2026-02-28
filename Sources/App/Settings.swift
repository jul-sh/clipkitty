import Foundation
import Carbon
import AppKit
@preconcurrency import CoreGraphics

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
        53: "Escape", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]

    /// Menu key equivalent strings (lowercase single char, or special char)
    private static let keyCodeEquivalents: [UInt32: String] = [
        49: " ", 36: "\r", 48: "\t"
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

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var hotKey: HotKey {
        didSet { save() }
    }

    @Published var maxDatabaseSizeGB: Double {
        didSet { save() }
    }

    /// Check if the app can post synthetic keyboard events (e.g. Cmd+V for direct paste)
    var hasPostEventPermission: Bool {
        return CGPreflightPostEventAccess()
    }

    /// Request permission to post synthetic keyboard events.
    /// Opens System Settings if not yet granted.
    /// Returns true if permissions are already granted.
    @discardableResult
    func requestPostEventPermission() -> Bool {
        return CGRequestPostEventAccess()
    }

    @Published var autoPasteEnabled: Bool {
        didSet { save() }
    }

    var pasteMode: PasteMode {
        guard hasPostEventPermission else { return .noPermission }
        return autoPasteEnabled ? .autoPaste : .copyOnly
    }


    #if !APP_STORE
    enum UpdateCheckState: Equatable {
        case idle
        case available
        case checkFailed
    }

    @Published var updateCheckState: UpdateCheckState = .idle

    /// Records when consecutive update-check failures started. Persisted to UserDefaults.
    var updateCheckFailingSince: Date? {
        get { defaults.object(forKey: updateCheckFailingSinceKey) as? Date }
        set { defaults.set(newValue, forKey: updateCheckFailingSinceKey) }
    }
    #endif

    let maxImageMegapixels: Double
    let imageCompressionQuality: Double

    #if !APP_STORE
    @Published var autoInstallUpdates: Bool {
        didSet { save() }
    }
    #endif

    @Published var launchAtLoginEnabled: Bool {
        didSet { save() }
    }

    /// When enabled, clicking menu bar icon opens ClipKitty directly, right-click shows menu
    /// When disabled (default), clicking shows the menu
    @Published var clickToOpenEnabled: Bool {
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

    /// Bundle IDs of apps whose clipboard content should be ignored
    @Published var ignoredAppBundleIds: Set<String> {
        didSet { save() }
    }

    private let defaults = UserDefaults.standard
    private let hotKeyKey = "hotKey"
    private let maxDbSizeKey = "maxDatabaseSizeGB"
    private let launchAtLoginKey = "launchAtLogin"
    private let autoPasteKey = "autoPasteEnabled"
    private let ignoreConfidentialKey = "ignoreConfidentialContent"
    private let ignoreTransientKey = "ignoreTransientContent"
    private let generateLinkPreviewsKey = "generateLinkPreviews"
    private let ignoredAppBundleIdsKey = "ignoredAppBundleIds"
    private let clickToOpenKey = "clickToOpenEnabled"
    #if !APP_STORE
    private let autoInstallUpdatesKey = "autoInstallUpdates"
    private let updateCheckFailingSinceKey = "updateCheckFailingSince"
    #endif

    private init() {
        // Initialize all stored properties first
        if let data = defaults.data(forKey: hotKeyKey),
           let decoded = try? JSONDecoder().decode(HotKey.self, from: data) {
            hotKey = decoded
        } else {
            hotKey = .default
        }

        if let stored = defaults.object(forKey: maxDbSizeKey) as? NSNumber {
            maxDatabaseSizeGB = stored.doubleValue
        } else {
            maxDatabaseSizeGB = 7.0
        }

        #if APP_STORE
        launchAtLoginEnabled = defaults.object(forKey: launchAtLoginKey) as? Bool ?? false
        #else
        launchAtLoginEnabled = defaults.object(forKey: launchAtLoginKey) as? Bool ?? true
        #endif
        autoPasteEnabled = defaults.object(forKey: autoPasteKey) as? Bool ?? true
        clickToOpenEnabled = defaults.object(forKey: clickToOpenKey) as? Bool ?? true
        #if !APP_STORE
        autoInstallUpdates = defaults.object(forKey: autoInstallUpdatesKey) as? Bool ?? true
        #endif

        // Privacy settings - default to enabled for user protection
        ignoreConfidentialContent = defaults.object(forKey: ignoreConfidentialKey) as? Bool ?? true
        ignoreTransientContent = defaults.object(forKey: ignoreTransientKey) as? Bool ?? true
        generateLinkPreviews = defaults.object(forKey: generateLinkPreviewsKey) as? Bool ?? true

        // Load ignored app bundle IDs
        if let storedIds = defaults.stringArray(forKey: ignoredAppBundleIdsKey) {
            ignoredAppBundleIds = Set(storedIds)
        } else {
            // Default ignored apps: Keychain Access and Passwords
            ignoredAppBundleIds = [
                "com.apple.keychainaccess",
                "com.apple.Passwords"
            ]
        }

        maxImageMegapixels = 2.0
        imageCompressionQuality = 0.3
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hotKey) {
            defaults.set(data, forKey: hotKeyKey)
        }
        defaults.set(maxDatabaseSizeGB, forKey: maxDbSizeKey)
        defaults.set(launchAtLoginEnabled, forKey: launchAtLoginKey)
        defaults.set(autoPasteEnabled, forKey: autoPasteKey)
        defaults.set(ignoreConfidentialContent, forKey: ignoreConfidentialKey)
        defaults.set(ignoreTransientContent, forKey: ignoreTransientKey)
        defaults.set(generateLinkPreviews, forKey: generateLinkPreviewsKey)
        defaults.set(Array(ignoredAppBundleIds), forKey: ignoredAppBundleIdsKey)
        defaults.set(clickToOpenEnabled, forKey: clickToOpenKey)
        #if !APP_STORE
        defaults.set(autoInstallUpdates, forKey: autoInstallUpdatesKey)
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
