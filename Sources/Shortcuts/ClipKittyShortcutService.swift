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
    /// No foreground session has opened a store in this app process yet (for
    /// example a background launch that only runs an intent). Reads may open
    /// the database directly, matching out-of-process behavior; saves must use
    /// the durable pending queue because a foreground bootstrap can begin at
    /// any moment and must never contend with another open on the same path.
    case unopened
    /// The foreground store was deliberately released for suspension (or its
    /// container was deallocated). Its teardown may still be draining, so
    /// nothing may open the database: saves go to the durable pending queue
    /// and reads fail until the next foreground session.
    case suspended
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
    /// Durably written to the pending share queue; the app ingests it the
    /// next time it runs with an open store.
    case queued
}

private enum ShortcutStoreSource {
    case appSession(@MainActor @Sendable () async -> ClipKittyShortcutStoreAvailability)
    case databasePath(@Sendable () throws -> String)
}

/// Where a save intent lands: the open store, or the durable pending share
/// queue that the app drains on its next foreground activation.
private enum ShortcutSaveDestination {
    case store(StoreSession)
    case pendingQueue
}

/// Attribution recorded on clips saved through the Shortcuts intents, whether
/// they are written to the store directly or ingested later from the queue.
private enum ShortcutSaveAttribution {
    static let sourceApp = "Shortcuts"
    static let sourceAppBundleId = "com.apple.shortcuts"
}

final class ClipKittyShortcutService: ClipKittyShortcutServicing {
    private let storeSource: ShortcutStoreSource
    private let standaloneDatabasePathProvider: @Sendable () throws -> String
    private let pendingShareDirectory: URL?
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
        standaloneDatabasePathProvider = databasePathProvider
        pendingShareDirectory = nil
        self.pasteboardClient = pasteboardClient
        self.imageDescriptionGenerator = imageDescriptionGenerator
    }

    init(
        sessionProvider: @escaping @MainActor @Sendable () async -> ClipKittyShortcutStoreAvailability,
        pasteboardClient: ShortcutPasteboardClient = .live,
        imageDescriptionGenerator: @escaping @Sendable (Data) async -> String? = { data in
            await ImageDescriptionGenerator.generateDescription(from: data)
        },
        standaloneDatabasePathProvider: @escaping @Sendable () throws -> String = {
            try ShortcutDatabasePath.resolve()
        },
        pendingShareDirectory: URL? = nil
    ) {
        storeSource = .appSession(sessionProvider)
        self.standaloneDatabasePathProvider = standaloneDatabasePathProvider
        self.pendingShareDirectory = pendingShareDirectory
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

        switch try await makeSaveDestination() {
        case let .store(session):
            let result = await session.repository.saveText(
                text: text,
                sourceApp: ShortcutSaveAttribution.sourceApp,
                sourceAppBundleId: ShortcutSaveAttribution.sourceAppBundleId
            )
            return try savedClip(from: result)
        case .pendingQueue:
            try enqueueDurably {
                try PendingShareQueue.enqueueText(
                    text,
                    sourceApp: ShortcutSaveAttribution.sourceApp,
                    sourceAppBundleId: ShortcutSaveAttribution.sourceAppBundleId,
                    in: pendingShareDirectory
                )
            }
            return .queued
        }
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
            switch try await makeSaveDestination() {
            case let .store(session):
                let result = await session.repository.saveImage(
                    imageData: data,
                    thumbnail: thumbnail,
                    sourceApp: ShortcutSaveAttribution.sourceApp,
                    sourceAppBundleId: ShortcutSaveAttribution.sourceAppBundleId,
                    isAnimated: isAnimated
                )
                if case let .success(itemId) = result, !itemId.isEmpty {
                    _ = await ImageDescriptionUpdater(
                        repository: session.repository,
                        generator: imageDescriptionGenerator
                    ).update(itemId: itemId, imageData: data)
                }
                return try savedClip(from: result)
            case .pendingQueue:
                // The ingest path re-validates the raw bytes and derives its
                // own thumbnail and description, so only the original data and
                // animation hint travel through the queue.
                try enqueueDurably {
                    try PendingShareQueue.enqueueImage(
                        imageData: data,
                        thumbnail: nil,
                        isAnimated: isAnimated,
                        sourceApp: ShortcutSaveAttribution.sourceApp,
                        sourceAppBundleId: ShortcutSaveAttribution.sourceAppBundleId,
                        in: pendingShareDirectory
                    )
                }
                return .queued
            }
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
            case .unopened:
                // No foreground session has ever owned the store in this
                // process, so a direct open behaves exactly like the
                // out-of-process Shortcuts path.
                return try makeStandaloneSession(
                    databasePathProvider: standaloneDatabasePathProvider
                )
            case .suspended:
                throw ClipKittyShortcutError.databaseOpenFailed("ClipKitty is suspended.")
            case let .unavailable(reason):
                throw ClipKittyShortcutError.databaseOpenFailed(reason)
            }
        case let .databasePath(databasePathProvider):
            return try makeStandaloneSession(databasePathProvider: databasePathProvider)
        }
    }

    /// Saves prefer the foreground session's store but degrade to the durable
    /// pending queue whenever the app process holds no open store: unlike
    /// reads, a save has a contention-free destination that survives until the
    /// next activation drains it.
    private func makeSaveDestination() async throws -> ShortcutSaveDestination {
        switch storeSource {
        case let .appSession(provider):
            switch await provider() {
            case let .ready(session):
                return .store(session)
            case .unopened, .suspended:
                return .pendingQueue
            case let .unavailable(reason):
                throw ClipKittyShortcutError.databaseOpenFailed(reason)
            }
        case let .databasePath(databasePathProvider):
            return try .store(makeStandaloneSession(databasePathProvider: databasePathProvider))
        }
    }

    private func enqueueDurably(_ enqueue: () throws -> Void) throws {
        do {
            try enqueue()
        } catch is PendingShareQueue.EnqueueError {
            throw ClipKittyShortcutError.operationFailed(
                "The item is too large for ClipKitty to save."
            )
        } catch {
            throw ClipKittyShortcutError.operationFailed(
                "Could not save the item for ClipKitty: \(error.localizedDescription)"
            )
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
