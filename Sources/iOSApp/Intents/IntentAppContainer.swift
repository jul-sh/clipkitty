import ClipKittyRust
import ClipKittyShared
import Foundation

/// Provides a shared ClipboardRepository for App Intents.
/// Intents may run in an extension process, so this uses a minimal bootstrap
/// without UI services.
@MainActor
enum IntentAppContainer {
    private static var _repository: ClipboardRepository?

    /// Override point for tests. When set, `repository` returns this instead of
    /// creating one from the default database path.
    static var _testRepository: ClipboardRepository?

    static var repository: ClipboardRepository {
        get throws {
            if let test = _testRepository { return test }
            if let existing = _repository { return existing }
            let repo = try createRepository()
            _repository = repo
            return repo
        }
    }

    private static func createRepository() throws -> ClipboardRepository {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let appDir = appSupport.appendingPathComponent("ClipKitty", isDirectory: true)
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let dbPath = appDir.appendingPathComponent("clipboard.db").path
        let store = try ClipKittyRust.ClipboardStore(dbPath: dbPath)
        return ClipboardRepository(store: store)
    }
}
