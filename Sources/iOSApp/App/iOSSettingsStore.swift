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

    #if ENABLE_SYNC
        var syncEnabled: Bool {
            didSet { save() }
        }
    #endif

    // MARK: - Keys

    private let hapticsEnabledKey = "iOSHapticsEnabled"
    private let generateLinkPreviewsKey = "iOSGenerateLinkPreviews"
    private let autoAddFromClipboardKey = "iOSAutoAddFromClipboard"
    #if ENABLE_SYNC
        private let syncEnabledKey = "iOSSyncEnabled"
    #endif

    // MARK: - Internals

    @ObservationIgnored
    private let defaults: UserDefaults

    @ObservationIgnored
    private var isInitializing = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        hapticsEnabled = defaults.object(forKey: hapticsEnabledKey) as? Bool ?? true
        generateLinkPreviews = defaults.object(forKey: generateLinkPreviewsKey) as? Bool ?? true
        autoAddFromClipboard = defaults.object(forKey: autoAddFromClipboardKey) as? Bool ?? false

        #if ENABLE_SYNC
            syncEnabled = defaults.object(forKey: syncEnabledKey) as? Bool ?? false
        #endif

        isInitializing = false
    }

    private func save() {
        guard !isInitializing else { return }
        defaults.set(hapticsEnabled, forKey: hapticsEnabledKey)
        defaults.set(generateLinkPreviews, forKey: generateLinkPreviewsKey)
        defaults.set(autoAddFromClipboard, forKey: autoAddFromClipboardKey)
        #if ENABLE_SYNC
            defaults.set(syncEnabled, forKey: syncEnabledKey)
        #endif
    }
}
