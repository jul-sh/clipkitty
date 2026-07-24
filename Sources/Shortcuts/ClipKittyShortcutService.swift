import ClipKittyContentServices
import ClipKittyCore
import ClipKittyRust
import ClipKittyStore
import Foundation

protocol ClipKittyShortcutServicing: Sendable {
    func saveText(_ text: String) async throws -> ShortcutSavedClip
    func saveCurrentClipboard() async throws -> ShortcutSavedClip
    func searchText(query: String, limit: Int) async throws -> [String]
    func fetchRecentText(limit: Int) async throws -> [String]
}

public enum ClipKittyShortcutStoreAvailability: Sendable {
    case ready(StoreSession)
    case unavailable(String)
}

public enum ClipKittyShortcutRuntime {
    private static let registry = ShortcutServiceRegistry()

    @TaskLocal static var serviceFactory: @Sendable () -> any ClipKittyShortcutServicing = {
        registry.makeService()
    }

    static func makeService() -> any ClipKittyShortcutServicing {
        serviceFactory()
    }

    public static func useStoreProvider(
        _ provider: @escaping @MainActor @Sendable () async -> ClipKittyShortcutStoreAvailability
    ) {
        registry.install {
            ClipKittyShortcutService(sessionProvider: provider)
        }
    }
}

private final class ShortcutServiceRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var serviceFactory: @Sendable () -> any ClipKittyShortcutServicing = {
        ClipKittyShortcutService()
    }

    func install(_ factory: @escaping @Sendable () -> any ClipKittyShortcutServicing) {
        lock.lock()
        defer { lock.unlock() }
        serviceFactory = factory
    }

    func makeService() -> any ClipKittyShortcutServicing {
        lock.lock()
        defer { lock.unlock() }
        return serviceFactory()
    }
}

struct ShortcutPasteboardClient {
    let read: @Sendable () async -> ShortcutPasteboardRead

    static let live = ShortcutPasteboardClient(
        read: {
            await ShortcutPasteboard.read()
        }
    )
}

enum ClipKittyShortcutError: Equatable, LocalizedError {
    case emptyText
    case emptyClipboard
    case unsupportedClipboardContent(String)
    case databasePathUnavailable(String)
    case databaseOpenFailed(String)
    case operationFailed(String)
    case readAccessDisabled

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Text cannot be empty."
        case .emptyClipboard:
            return "The clipboard is empty."
        case let .unsupportedClipboardContent(reason):
            return reason
        case let .databasePathUnavailable(reason):
            return "Could not locate ClipKitty's database: \(reason)"
        case let .databaseOpenFailed(reason):
            return "Could not open ClipKitty's database: \(reason)"
        case let .operationFailed(reason):
            return reason
        case .readAccessDisabled:
            return "Enable 'Allow Shortcuts to read clipboard history' in ClipKitty Settings to use this action."
        }
    }
}

/// Privacy gate for the read-only Shortcuts actions.
///
/// The SAVE/write intents pose no exfiltration risk, but the GET/SEARCH
/// intents return raw clip text with `openAppWhenRun = false` and no auth or
/// consent, and that history may contain passwords, 2FA codes, or other
/// secrets. The gate lets a privacy-conscious user switch history access off
/// for automations (via the "Allow Shortcuts to Read History" setting) while
/// still allowing Shortcuts to save new clips. It defaults ON, so the read
/// intents work out of the box.
///
/// The setting is persisted by the app to standard `UserDefaults` under the
/// `allowShortcutsReadAccess` key. Reading it directly here (rather than
/// threading the full settings store through the intent runtime) keeps this
/// gate low-coupling and available in every context the intents run in.
enum ShortcutReadAccessGate {
    static let settingKey = "allowShortcutsReadAccess"

    static var isReadAccessAllowed: Bool {
        // Default ON when the setting has never been written; the user can turn
        // it off to deny automations access to clipboard history.
        return UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
    }
}

enum ShortcutSavedClip: Equatable {
    case inserted(id: String)
    case duplicate
}

private enum ShortcutStoreSource {
    case appSession(@MainActor @Sendable () async -> ClipKittyShortcutStoreAvailability)
    case databasePath(@Sendable () throws -> String)
}

final class ClipKittyShortcutService: ClipKittyShortcutServicing {
    private let storeSource: ShortcutStoreSource
    private let pasteboardClient: ShortcutPasteboardClient
    private let imageDescriptionGenerator: @Sendable (Data) async -> String?

    init(
        databasePathProvider: @escaping @Sendable () throws -> String = {
            try ShortcutDatabasePath.resolve()
        },
        pasteboardClient: ShortcutPasteboardClient = .live,
        imageDescriptionGenerator: @escaping @Sendable (Data) async -> String? = { data in
            await ImageDescriptionGenerator.generateDescription(from: data)
        }
    ) {
        storeSource = .databasePath(databasePathProvider)
        self.pasteboardClient = pasteboardClient
        self.imageDescriptionGenerator = imageDescriptionGenerator
    }

    init(
        sessionProvider: @escaping @MainActor @Sendable () async -> ClipKittyShortcutStoreAvailability,
        pasteboardClient: ShortcutPasteboardClient = .live,
        imageDescriptionGenerator: @escaping @Sendable (Data) async -> String? = { data in
            await ImageDescriptionGenerator.generateDescription(from: data)
        }
    ) {
        storeSource = .appSession(sessionProvider)
        self.pasteboardClient = pasteboardClient
        self.imageDescriptionGenerator = imageDescriptionGenerator
    }

    convenience init(
        databasePath: String,
        pasteboardClient: ShortcutPasteboardClient = .live,
        imageDescriptionGenerator: @escaping @Sendable (Data) async -> String? = { data in
            await ImageDescriptionGenerator.generateDescription(from: data)
        }
    ) {
        self.init(
            databasePathProvider: { databasePath },
            pasteboardClient: pasteboardClient,
            imageDescriptionGenerator: imageDescriptionGenerator
        )
    }

    func saveText(_ text: String) async throws -> ShortcutSavedClip {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClipKittyShortcutError.emptyText
        }

        let access = try await makeStoreAccess()
        let result = await access.repository.saveText(
            text: text,
            sourceApp: "Shortcuts",
            sourceAppBundleId: "com.apple.shortcuts"
        )
        return try savedClip(from: result)
    }

    func saveCurrentClipboard() async throws -> ShortcutSavedClip {
        let clipboardRead = await pasteboardClient.read()
        switch clipboardRead {
        case let .content(content):
            return try await save(content)
        case .empty:
            throw ClipKittyShortcutError.emptyClipboard
        case let .unsupported(reason):
            throw ClipKittyShortcutError.unsupportedClipboardContent(reason)
        }
    }

    func searchText(query: String, limit: Int) async throws -> [String] {
        try await fetchText(query: query, limit: limit)
    }

    func fetchRecentText(limit: Int) async throws -> [String] {
        try await fetchText(query: "", limit: limit)
    }

    private func save(_ content: ShortcutSavableContent) async throws -> ShortcutSavedClip {
        switch content {
        case let .text(text):
            return try await saveText(text)
        case let .image(data, thumbnail, isAnimated):
            let access = try await makeStoreAccess()
            let result = await access.repository.saveImage(
                imageData: data,
                thumbnail: thumbnail,
                sourceApp: "Shortcuts",
                sourceAppBundleId: "com.apple.shortcuts",
                isAnimated: isAnimated
            )
            if case let .success(itemId) = result, !itemId.isEmpty {
                _ = await ImageDescriptionUpdater(
                    repository: access.repository,
                    generator: imageDescriptionGenerator
                ).update(itemId: itemId, imageData: data)
            }
            return try savedClip(from: result)
        }
    }

    private func fetchText(query: String, limit: Int) async throws -> [String] {
        // Privacy gate: never return clipboard history to a read intent when the
        // user has turned off Shortcuts read access. Default ON. Only the read
        // path (search / recent) is gated; the SAVE path never calls this.
        guard ShortcutReadAccessGate.isReadAccessAllowed else {
            throw ClipKittyShortcutError.readAccessDisabled
        }

        let repository = try await makeStoreAccess().repository
        let result = await repository.search(
            query: query,
            filter: .contentType(contentType: .text),
            presentation: .compactRow
        )

        let matches: [ItemMatch]
        switch result {
        case let .success(searchResult):
            matches = searchResult.matches
        case .cancelled:
            throw ClipKittyShortcutError.operationFailed("The ClipKitty search was cancelled.")
        case let .failure(error):
            throw ClipKittyShortcutError.operationFailed(error.localizedDescription)
        }

        let clampedLimit = Self.clampLimit(limit)
        var values: [String] = []
        for match in matches.prefix(clampedLimit) {
            guard let item = await repository.fetchItem(id: match.itemMetadata.itemId) else {
                continue
            }
            switch item.content {
            case let .text(value):
                values.append(value)
            case .color, .link, .image, .file:
                continue
            }
        }
        return values
    }

    private func makeStoreAccess() async throws -> StoreSession {
        switch storeSource {
        case let .appSession(provider):
            switch await provider() {
            case let .ready(session):
                return session
            case let .unavailable(reason):
                throw ClipKittyShortcutError.databaseOpenFailed(reason)
            }
        case let .databasePath(databasePathProvider):
            return try makeStandaloneSession(databasePathProvider: databasePathProvider)
        }
    }

    private func makeStandaloneSession(
        databasePathProvider: @Sendable () throws -> String
    ) throws -> StoreSession {
        let dbPath: String
        do {
            dbPath = try databasePathProvider()
        } catch let error as ClipKittyShortcutError {
            throw error
        } catch {
            throw ClipKittyShortcutError.databasePathUnavailable(error.localizedDescription)
        }

        do {
            return try StoreOpener.open(
                path: dbPath,
                repairStrategy: .rebuildImmediately
            )
        } catch {
            throw ClipKittyShortcutError.databaseOpenFailed(error.localizedDescription)
        }
    }

    private func savedClip(
        from result: Result<String, ClipboardError>
    ) throws -> ShortcutSavedClip {
        switch result {
        case let .success(itemId):
            return itemId.isEmpty ? .duplicate : .inserted(id: itemId)
        case let .failure(error):
            throw ClipKittyShortcutError.operationFailed(error.localizedDescription)
        }
    }

    private static func clampLimit(_ limit: Int) -> Int {
        min(max(limit, 1), 50)
    }
}

private enum ShortcutDatabasePath {
    static func resolve() throws -> String {
        #if os(macOS)
            guard let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw ClipKittyShortcutError.databasePathUnavailable("Application Support is unavailable.")
            }
            let appDir = appSupport.appendingPathComponent("ClipKitty", isDirectory: true)
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            return appDir.appendingPathComponent("clipboard.sqlite").path
        #else
            DatabasePath.migrateIfNeeded()
            return try DatabasePath.resolve()
        #endif
    }
}
