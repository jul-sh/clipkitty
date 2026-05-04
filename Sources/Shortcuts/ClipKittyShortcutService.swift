import ClipKittyRust
import ClipKittyShared
import Foundation

protocol ClipKittyShortcutServicing: Sendable {
    func saveText(_ text: String) async throws -> ShortcutSavedClip
    func saveCurrentClipboard() async throws -> ShortcutSavedClip
    func searchText(query: String, limit: Int) async throws -> [String]
    func fetchRecentText(limit: Int) async throws -> [String]
    func copyLatestText() async throws -> String
}

enum ClipKittyShortcutRuntime {
    @TaskLocal static var serviceFactory: @Sendable () -> any ClipKittyShortcutServicing = {
        ClipKittyShortcutService()
    }

    static func makeService() -> any ClipKittyShortcutServicing {
        serviceFactory()
    }
}

struct ShortcutPasteboardClient: Sendable {
    let read: @Sendable () async -> ShortcutPasteboardRead
    let writeText: @Sendable (String) async -> Void

    static let live = ShortcutPasteboardClient(
        read: {
            await ShortcutPasteboard.read()
        },
        writeText: { text in
            await ShortcutPasteboard.writeText(text)
        }
    )
}

enum ClipKittyShortcutError: Equatable, LocalizedError, Sendable {
    case emptyText
    case emptyClipboard
    case unsupportedClipboardContent(String)
    case databasePathUnavailable(String)
    case databaseOpenFailed(String)
    case operationFailed(String)
    case noTextClips

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
        case .noTextClips:
            return "ClipKitty does not have any text clips yet."
        }
    }
}

enum ShortcutSavedClip: Equatable, Sendable {
    case inserted(id: String)
    case duplicate
}

private enum ShortcutTextLookup: Sendable {
    case found(String)
    case notFound
}

private enum ShortcutTextExtraction: Sendable {
    case value(String)
    case unsupported

    static func parse(_ content: ClipboardContent) -> Self {
        switch content {
        case let .text(value):
            return .value(value)
        case .color, .link, .image, .file:
            return .unsupported
        }
    }
}

final class ClipKittyShortcutService: ClipKittyShortcutServicing {
    private let databasePathProvider: @Sendable () throws -> String
    private let pasteboardClient: ShortcutPasteboardClient

    init(
        databasePathProvider: @escaping @Sendable () throws -> String = {
            try ShortcutDatabasePath.resolve()
        },
        pasteboardClient: ShortcutPasteboardClient = .live
    ) {
        self.databasePathProvider = databasePathProvider
        self.pasteboardClient = pasteboardClient
    }

    convenience init(databasePath: String, pasteboardClient: ShortcutPasteboardClient = .live) {
        self.init(databasePathProvider: { databasePath }, pasteboardClient: pasteboardClient)
    }

    func saveText(_ text: String) async throws -> ShortcutSavedClip {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClipKittyShortcutError.emptyText
        }

        let repository = try makeRepository()
        let result = await repository.saveText(
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

    func copyLatestText() async throws -> String {
        let values = try await fetchRecentText(limit: 1)
        switch firstText(in: values) {
        case let .found(value):
            await pasteboardClient.writeText(value)
            return value
        case .notFound:
            throw ClipKittyShortcutError.noTextClips
        }
    }

    private func save(_ content: ShortcutSavableContent) async throws -> ShortcutSavedClip {
        switch content {
        case let .text(text):
            return try await saveText(text)
        case let .image(data, thumbnail, isAnimated):
            let repository = try makeRepository()
            let result = await repository.saveImage(
                imageData: data,
                thumbnail: thumbnail,
                sourceApp: "Shortcuts",
                sourceAppBundleId: "com.apple.shortcuts",
                isAnimated: isAnimated
            )
            return try savedClip(from: result)
        }
    }

    private func fetchText(query: String, limit: Int) async throws -> [String] {
        let repository = try makeRepository()
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
            switch ShortcutTextExtraction.parse(item.content) {
            case let .value(value):
                values.append(value)
            case .unsupported:
                continue
            }
        }
        return values
    }

    private func makeRepository() throws -> ClipboardRepository {
        let dbPath: String
        do {
            dbPath = try databasePathProvider()
        } catch let error as ClipKittyShortcutError {
            throw error
        } catch {
            throw ClipKittyShortcutError.databasePathUnavailable(error.localizedDescription)
        }

        let plan: StoreBootstrapPlan
        do {
            plan = try inspectStoreBootstrap(dbPath: dbPath)
        } catch {
            throw ClipKittyShortcutError.databaseOpenFailed(error.localizedDescription)
        }

        let store: ClipKittyRust.ClipboardStore
        do {
            store = try ClipKittyRust.ClipboardStore(dbPath: dbPath)
            switch plan {
            case .ready:
                break
            case .rebuildIndex:
                try store.rebuildIndex()
            }
        } catch {
            throw ClipKittyShortcutError.databaseOpenFailed(error.localizedDescription)
        }

        return ClipboardRepository(store: store)
    }

    private func savedClip(from result: Result<String, ClipboardError>) throws -> ShortcutSavedClip {
        switch result {
        case let .success(itemId):
            if itemId.isEmpty {
                return .duplicate
            }
            return .inserted(id: itemId)
        case let .failure(error):
            throw ClipKittyShortcutError.operationFailed(error.localizedDescription)
        }
    }

    private func firstText(in values: [String]) -> ShortcutTextLookup {
        guard let first = values.first else { return .notFound }
        return .found(first)
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
