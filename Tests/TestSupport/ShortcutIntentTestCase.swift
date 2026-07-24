@testable import ClipKittyShortcuts
import XCTest

@MainActor
class ShortcutIntentTestCase: TemporaryDirectoryTestCase {
    func makeService(
        pasteboardRead: ShortcutPasteboardRead = .empty
    ) -> ClipKittyShortcutService {
        makeService(pasteboardClient: ShortcutPasteboardClient(read: { pasteboardRead }))
    }

    func makeService(
        pasteboardClient: ShortcutPasteboardClient
    ) -> ClipKittyShortcutService {
        ClipKittyShortcutService(
            databasePath: databasePath(),
            pasteboardClient: pasteboardClient,
            imageDescriptionGenerator: { _ in nil }
        )
    }

    func withShortcutService<T>(
        _ service: ClipKittyShortcutService,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await ClipKittyShortcutRuntime.$serviceFactory.withValue({ service }) {
            try await operation()
        }
    }

    func assertThrowsShortcutError<T>(
        _ expectedError: ClipKittyShortcutError,
        operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expectedError) to throw")
        } catch let error as ClipKittyShortcutError {
            XCTAssertEqual(error, expectedError)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
