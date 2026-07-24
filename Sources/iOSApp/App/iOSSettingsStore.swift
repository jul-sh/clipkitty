import ClipKittyCore
import Foundation

/// UserDefaults-backed settings for the iOS app.
@MainActor
@Observable
final class iOSSettingsStore {
    // MARK: - Settings

    var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: hapticsEnabledKey) }
    }

    var generateLinkPreviews: Bool {
        didSet { defaults.set(generateLinkPreviews, forKey: generateLinkPreviewsKey) }
    }

    var autoAddFromClipboard: Bool {
        didSet { defaults.set(autoAddFromClipboard, forKey: autoAddFromClipboardKey) }
    }

    /// Whether Shortcuts intents may read clipboard history. Default ON; the
    /// read-intents are gated on this so a privacy-conscious user can turn off
    /// history access for automations while still allowing them to save clips.
    var allowShortcutsReadAccess: Bool {
        didSet { defaults.set(allowShortcutsReadAccess, forKey: allowShortcutsReadAccessKey) }
    }

    /// Whether to capture clips the source marked as sensitive (passwords, OTPs,
    /// tokens; `org.nspasteboard.ConcealedType` and friends). Default OFF, so
    /// password-manager and other secret clips are not added to history unless
    /// the user opts in.
    var captureSensitiveClips: Bool {
        didSet { defaults.set(captureSensitiveClips, forKey: captureSensitiveClipsKey) }
    }

    /// The UI typeface used across the app. Mirrors the macOS `fontPreference`.
    var fontPreference: AppFontPreference {
        didSet { defaults.set(fontPreference.rawValue, forKey: fontPreferenceKey) }
    }

    /// Character spacing for preview text — monospaced vs proportional.
    /// Mirrors the macOS `previewFontPreference`.
    var previewFontPreference: PreviewFontPreference {
        didSet { defaults.set(previewFontPreference.rawValue, forKey: previewFontPreferenceKey) }
    }

    /// Whether the user has dismissed the clipboard-permission hint in Settings.
    var permissionHintDismissed: Bool {
        didSet { defaults.set(permissionHintDismissed, forKey: permissionHintDismissedKey) }
    }

    /// Maximum database size in gigabytes; oldest items are pruned beyond it.
    /// Matches the macOS default of 7 GB.
    var maxDatabaseSizeGB: Double {
        didSet { defaults.set(maxDatabaseSizeGB, forKey: maxDatabaseSizeGBKey) }
    }

    #if ENABLE_ICLOUD_SYNC
        var syncEnabled: Bool {
            didSet { defaults.set(syncEnabled, forKey: syncEnabledKey) }
        }
    #endif

    // MARK: - Pasteboard ingest state

    /// The pasteboard `changeCount` already ingested by auto-add. This is
    /// state, not a user-facing preference, but it uses the same per-key
    /// persistence strategy as the user-facing settings.
    /// Persistence is required because backgrounding tears down the container
    /// and rebootstraps on foreground.
    @ObservationIgnored
    var lastIngestedPasteboardChangeCount: Int {
        didSet { defaults.set(lastIngestedPasteboardChangeCount, forKey: lastIngestedPasteboardChangeCountKey) }
    }

    // MARK: - Keys

    private let hapticsEnabledKey = "iOSHapticsEnabled"
    private let generateLinkPreviewsKey = "iOSGenerateLinkPreviews"
    private let autoAddFromClipboardKey = "iOSAutoAddFromClipboard"
    private let allowShortcutsReadAccessKey = "allowShortcutsReadAccess"
    private let captureSensitiveClipsKey = "captureSensitiveClips"
    private let maxDatabaseSizeGBKey = "iOSMaxDatabaseSizeGB"
    private let fontPreferenceKey = "iOSFontPreference"
    private let previewFontPreferenceKey = "iOSPreviewFontPreference"
    private let permissionHintDismissedKey = "iOSPermissionHintDismissed"
    private let lastIngestedPasteboardChangeCountKey = "iOSLastIngestedPasteboardChangeCount"
    #if ENABLE_ICLOUD_SYNC
        private let syncEnabledKey = "iOSSyncEnabled"
    #endif

    // MARK: - Internals

    @ObservationIgnored
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        hapticsEnabled = defaults.object(forKey: hapticsEnabledKey) as? Bool ?? true
        generateLinkPreviews = defaults.object(forKey: generateLinkPreviewsKey) as? Bool ?? true
        autoAddFromClipboard = defaults.object(forKey: autoAddFromClipboardKey) as? Bool ?? false
        allowShortcutsReadAccess = defaults.object(forKey: allowShortcutsReadAccessKey) as? Bool ?? true
        captureSensitiveClips = defaults.object(forKey: captureSensitiveClipsKey) as? Bool ?? false
        maxDatabaseSizeGB = defaults.object(forKey: maxDatabaseSizeGBKey) as? Double ?? 7.0
        fontPreference = defaults.string(forKey: fontPreferenceKey)
            .flatMap(AppFontPreference.init(rawValue:)) ?? .system
        previewFontPreference = defaults.string(forKey: previewFontPreferenceKey)
            .flatMap(PreviewFontPreference.init(rawValue:)) ?? .coding
        permissionHintDismissed = defaults.object(forKey: permissionHintDismissedKey) as? Bool ?? false
        lastIngestedPasteboardChangeCount = defaults.object(forKey: lastIngestedPasteboardChangeCountKey) as? Int ?? 0

        #if ENABLE_ICLOUD_SYNC
            syncEnabled = defaults.object(forKey: syncEnabledKey) as? Bool ?? false
        #endif
    }
}
