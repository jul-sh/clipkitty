import AppKit
@testable import ClipKittyMacPlatform
import XCTest

/// A pasteboard whose writes can be made to fail, the way `NSPasteboard`
/// reports failure when another process owns the pasteboard or the data
/// cannot be promised.
private final class FailingPasteboard: PasteboardProtocol {
    var changeCount = 0
    var failingTypes: Set<NSPasteboard.PasteboardType> = []
    private(set) var writtenTypes: [NSPasteboard.PasteboardType] = []

    @discardableResult
    func clearContents() -> Int {
        changeCount += 1
        return changeCount
    }

    func setString(_: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        write(type)
    }

    func setData(_: Data?, forType type: NSPasteboard.PasteboardType) -> Bool {
        write(type)
    }

    func setPropertyList(_: Any, forType type: NSPasteboard.PasteboardType) -> Bool {
        write(type)
    }

    func declareTypes(_: [NSPasteboard.PasteboardType], owner _: Any?) -> Int {
        changeCount += 1
        return changeCount
    }

    func string(forType _: NSPasteboard.PasteboardType) -> String? {
        nil
    }

    func data(forType _: NSPasteboard.PasteboardType) -> Data? {
        nil
    }

    func types() -> [NSPasteboard.PasteboardType]? {
        nil
    }

    func readFileURLs() -> [URL] {
        []
    }

    private func write(_ type: NSPasteboard.PasteboardType) -> Bool {
        writtenTypes.append(type)
        changeCount += 1
        return !failingTypes.contains(type)
    }
}

@MainActor
final class PasteServiceTests: XCTestCase {
    func testTextWriteReportsSuccessAndPostWriteChangeCount() {
        let pasteboard = FailingPasteboard()
        let service = PasteService(pasteboard: pasteboard)

        let outcome = service.writeText("hello")

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.changeCount, pasteboard.changeCount)
        XCTAssertEqual(pasteboard.writtenTypes, [.string])
    }

    func testFailedTextWriteIsReportedButStillAcknowledgesChangeCount() {
        let pasteboard = FailingPasteboard()
        pasteboard.failingTypes = [.string]
        let service = PasteService(pasteboard: pasteboard)

        let outcome = service.writeText("hello")

        XCTAssertFalse(outcome.succeeded)
        // `clearContents()` already bumped the count; the monitor must still
        // acknowledge it or it would ingest the emptied pasteboard.
        XCTAssertEqual(outcome.changeCount, pasteboard.changeCount)
        XCTAssertGreaterThan(outcome.changeCount, 0)
    }

    func testStaticImageWriteFailureIsReported() {
        let pasteboard = FailingPasteboard()
        pasteboard.failingTypes = [.tiff]
        let service = PasteService(pasteboard: pasteboard)

        XCTAssertFalse(service.writeStaticImage(Data([0x4D, 0x4D])).succeeded)
    }

    func testAnimatedImageSucceedsWhenOnlyTheTiffFallbackFails() {
        let pasteboard = FailingPasteboard()
        pasteboard.failingTypes = [.tiff]
        let service = PasteService(pasteboard: pasteboard)

        let outcome = service.writeAnimatedImage(gifData: Data([0x47, 0x49, 0x46]), tiffFallback: Data([0x4D]))

        // The GIF is the payload; a missing TIFF fallback only costs
        // compatibility with apps that cannot read GIFs.
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(pasteboard.writtenTypes, [PasteService.gifType, .tiff])
    }

    func testAnimatedImageFailsWhenTheGifWriteFails() {
        let pasteboard = FailingPasteboard()
        pasteboard.failingTypes = [PasteService.gifType, .tiff]
        let service = PasteService(pasteboard: pasteboard)

        XCTAssertFalse(service.writeAnimatedImage(gifData: Data([0x47]), tiffFallback: Data([0x4D])).succeeded)
    }
}
