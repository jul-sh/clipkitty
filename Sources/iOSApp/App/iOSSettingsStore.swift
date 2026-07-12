import ClipKittyShared
import Foundation

/// UserDefaults-backed settings for the iOS app.
@MainActor
@Observable
final class iOSSettingsStore {
    // MARK: - Settings

    var hapticsEnabled: Bool {
        didSet { save() }
    }

    var generateLinkPreviews: Bool {
        didSet { save() }
    }

    var autoAddFromClipboard: Bool {
        didSet { save() }
    }

    /// The UI typeface used across the app. Mirrors the macOS `fontPreference`.
    var fontPreference: AppFontPreference {
        didSet { save() }
    }

    /// Character spacing for preview text — monospaced vs proportional.
    /// Mirrors the macOS `previewFontPreference`.
    var previewFontPreference: PreviewFontPreference {
        didSet { save() }
    }

    /// Whether the user has dismissed the clipboard-permission hint in Settings.
    var permissionHintDismissed: Bool {
        didSet { save() }
    }

    /// Maximum database size in gigabytes; oldest items are pruned beyond it.
    /// Matches the macOS default of 7 GB.
    var maxDatabaseSizeGB: Double {
        didSet { save() }
    }

    #if ENABLE_ICLOUD_SYNC
        var syncEnabled: Bool {
            didSet { save() }
        }
    #endif

    // MARK: - Pasteboard ingest state

    /// The pasteboard `changeCount` already ingested by auto-add (or by the
    /// keyboard's capture — see `PasteboardIngestState`). This is state, not a
    /// user-facing preference, so it bypasses the `isInitializing`/`save()`
    /// flow and writes straight through. Persistence is required because
    /// backgrounding tears down the container and rebootstraps on foreground;
    /// App Group storage is required so the keyboard extension shares it.
    @ObservationIgnored
    var lastIngestedPasteboardChangeCount: Int {
        didSet { PasteboardIngestState.recordChangeCount(lastIngestedPasteboardChangeCount, defaults: ingestStateDefaults) }
    }

    /// Re-reads the shared marker. The keyboard advances it while this store's
    /// in-memory copy is alive but the app is backgrounded; auto-add refreshes
    /// before comparing so a keyboard-captured generation isn't ingested twice.
    func refreshPasteboardIngestState() {
        if let shared = PasteboardIngestState.lastChangeCount(defaults: ingestStateDefaults) {
            lastIngestedPasteboardChangeCount = shared
        }
    }

    // MARK: - Keys

    private let hapticsEnabledKey = "iOSHapticsEnabled"
    private let generateLinkPreviewsKey = "iOSGenerateLinkPreviews"
    private let autoAddFromClipboardKey = "iOSAutoAddFromClipboard"
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

    /// Where the shared pasteboard-ingest marker lives (App Group suite in
    /// production; injected in tests to stay hermetic).
    @ObservationIgnored
    private let ingestStateDefaults: UserDefaults?

    @ObservationIgnored
    private var isInitializing = true

    init(defaults: UserDefaults = .standard, ingestStateDefaults: UserDefaults? = nil) {
        self.defaults = defaults
        self.ingestStateDefaults = ingestStateDefaults

        hapticsEnabled = defaults.object(forKey: hapticsEnabledKey) as? Bool ?? true
        generateLinkPreviews = defaults.object(forKey: generateLinkPreviewsKey) as? Bool ?? true
        autoAddFromClipboard = defaults.object(forKey: autoAddFromClipboardKey) as? Bool ?? false
        maxDatabaseSizeGB = defaults.object(forKey: maxDatabaseSizeGBKey) as? Double ?? 7.0
        fontPreference = defaults.string(forKey: fontPreferenceKey)
            .flatMap(AppFontPreference.init(rawValue:)) ?? .system
        previewFontPreference = defaults.string(forKey: previewFontPreferenceKey)
            .flatMap(PreviewFontPreference.init(rawValue:)) ?? .coding
        permissionHintDismissed = defaults.object(forKey: permissionHintDismissedKey) as? Bool ?? false
        // Prefer the shared App Group marker; fall back to the pre-keyboard
        // per-process value so an update doesn't re-ingest the current
        // pasteboard generation.
        lastIngestedPasteboardChangeCount = PasteboardIngestState.lastChangeCount(defaults: ingestStateDefaults)
            ?? defaults.object(forKey: lastIngestedPasteboardChangeCountKey) as? Int ?? 0

        #if ENABLE_ICLOUD_SYNC
            syncEnabled = defaults.object(forKey: syncEnabledKey) as? Bool ?? false
        #endif

        isInitializing = false
    }

    private func save() {
        guard !isInitializing else { return }
        defaults.set(hapticsEnabled, forKey: hapticsEnabledKey)
        defaults.set(generateLinkPreviews, forKey: generateLinkPreviewsKey)
        defaults.set(autoAddFromClipboard, forKey: autoAddFromClipboardKey)
        defaults.set(maxDatabaseSizeGB, forKey: maxDatabaseSizeGBKey)
        defaults.set(fontPreference.rawValue, forKey: fontPreferenceKey)
        defaults.set(previewFontPreference.rawValue, forKey: previewFontPreferenceKey)
        defaults.set(permissionHintDismissed, forKey: permissionHintDismissedKey)
        #if ENABLE_ICLOUD_SYNC
            defaults.set(syncEnabled, forKey: syncEnabledKey)
        #endif
    }
}
