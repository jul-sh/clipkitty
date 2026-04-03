import ClipKittyRust
import ClipKittyShared
import Foundation

/// Provides a shared ClipboardRepository for the Share Extension.
/// Mirrors `IntentAppContainer` — lightweight bootstrap without UI services.
@MainActor
enum ShareExtensionContainer {
    private static var _repository: ClipboardRepository?

    /// Test-only override. When set, `repository` returns this instead of
    /// bootstrapping from the default database path.
    static var testRepositoryOverride: ClipboardRepository?

    static var repository: ClipboardRepository {
        get throws {
            if let override = testRepositoryOverride { return override }
            if let existing = _repository { return existing }
            let repo = try createRepository()
            _repository = repo
            return repo
        }
    }

    private static func createRepository() throws -> ClipboardRepository {
        let dbPath = try DatabasePath.resolve()
        let store = try ClipKittyRust.ClipboardStore(dbPath: dbPath)
        return ClipboardRepository(store: store)
    }
}
