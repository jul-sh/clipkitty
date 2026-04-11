@testable import ClipKittyiOS
import ClipKittyRust
import UniformTypeIdentifiers
import XCTest

final class ClipboardContentExportTests: XCTestCase {
    // MARK: - Text

    func testTextExportProducesPlainText() {
        let payload = ClipboardExportPayload(content: .text(value: "hello world"))
        guard case let .text(value) = payload else {
            XCTFail("Expected .text payload")
            return
        }
        XCTAssertEqual(value, "hello world")
    }

    func testTextShareItemsContainsString() {
        let payload = ClipboardExportPayload(content: .text(value: "hello"))
        XCTAssertEqual(payload.shareItems.count, 1)
        XCTAssertEqual(payload.shareItems.first as? String, "hello")
    }

    func testTextMakeItemProviderNotNil() {
        let payload = ClipboardExportPayload(content: .text(value: "hello"))
        XCTAssertNotNil(payload.makeItemProvider())
    }

    // MARK: - Color

    func testColorExportProducesColorPayload() {
        let payload = ClipboardExportPayload(content: .color(value: "#FF0000"))
        guard case let .color(value) = payload else {
            XCTFail("Expected .color payload")
            return
        }
        XCTAssertEqual(value, "#FF0000")
    }

    func testColorShareItemsContainsString() {
        let payload = ClipboardExportPayload(content: .color(value: "#00FF00"))
        XCTAssertEqual(payload.shareItems.first as? String, "#00FF00")
    }

    // MARK: - Link (valid URL)

    func testValidLinkExportProducesURL() {
        let payload = ClipboardExportPayload(
            content: .link(url: "https://example.com", metadataState: .failed)
        )
        guard case let .url(url, fallback) = payload else {
            XCTFail("Expected .url payload")
            return
        }
        XCTAssertEqual(url.absoluteString, "https://example.com")
        XCTAssertEqual(fallback, "https://example.com")
    }

    func testValidLinkShareItemsContainsURL() {
        let payload = ClipboardExportPayload(
            content: .link(url: "https://example.com", metadataState: .failed)
        )
        XCTAssertTrue(payload.shareItems.first is URL)
    }

    func testValidLinkMakeItemProviderNotNil() {
        let payload = ClipboardExportPayload(
            content: .link(url: "https://example.com", metadataState: .failed)
        )
        let provider = payload.makeItemProvider()
        XCTAssertNotNil(provider)
    }

    // MARK: - Link (invalid URL)

    func testInvalidLinkFallsBackToText() {
        let payload = ClipboardExportPayload(
            content: .link(url: "not a valid url %%", metadataState: .failed)
        )
        guard case let .text(value) = payload else {
            XCTFail("Expected .text fallback for invalid URL, got \(payload)")
            return
        }
        XCTAssertEqual(value, "not a valid url %%")
    }

    // MARK: - Image

    func testImageExportDetectsPNG() {
        // Minimal PNG header
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                              0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52])
        let payload = ClipboardExportPayload(
            content: .image(data: pngHeader, description: "test", isAnimated: false)
        )
        guard case let .image(_, contentType, _) = payload else {
            XCTFail("Expected .image payload")
            return
        }
        XCTAssertEqual(contentType, .png)
    }

    func testImageExportDetectsJPEG() {
        let jpegHeader = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: UInt8(0), count: 8))
        let payload = ClipboardExportPayload(
            content: .image(data: jpegHeader, description: "test", isAnimated: false)
        )
        guard case let .image(_, contentType, _) = payload else {
            XCTFail("Expected .image payload")
            return
        }
        XCTAssertEqual(contentType, .jpeg)
    }

    func testImageExportFallsToPNGForUnknownType() {
        let unknownData = Data(Array(repeating: UInt8(0xAB), count: 16))
        let payload = ClipboardExportPayload(
            content: .image(data: unknownData, description: "test", isAnimated: false)
        )
        guard case let .image(_, contentType, _) = payload else {
            XCTFail("Expected .image payload")
            return
        }
        XCTAssertEqual(contentType, .png)
    }

    func testEmptyImageIsUnsupported() {
        let payload = ClipboardExportPayload(
            content: .image(data: Data(), description: "empty", isAnimated: false)
        )
        guard case let .unsupported(reason) = payload else {
            XCTFail("Expected .unsupported payload")
            return
        }
        guard case .emptyImage = reason else {
            XCTFail("Expected .emptyImage reason")
            return
        }
    }

    func testImageMakeItemProviderNotNil() {
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                              0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52])
        let payload = ClipboardExportPayload(
            content: .image(data: pngHeader, description: "test", isAnimated: false)
        )
        XCTAssertNotNil(payload.makeItemProvider())
    }

    // MARK: - File (unsupported)

    func testFileExportIsUnsupported() {
        let payload = ClipboardExportPayload(
            content: .file(displayName: "doc.pdf", files: [])
        )
        guard case let .unsupported(reason) = payload else {
            XCTFail("Expected .unsupported payload")
            return
        }
        guard case .file = reason else {
            XCTFail("Expected .file reason")
            return
        }
    }

    func testUnsupportedShareItemsEmpty() {
        let payload = ClipboardExportPayload(
            content: .file(displayName: "doc.pdf", files: [])
        )
        XCTAssertTrue(payload.shareItems.isEmpty)
    }

    func testUnsupportedMakeItemProviderNil() {
        let payload = ClipboardExportPayload(
            content: .file(displayName: "doc.pdf", files: [])
        )
        XCTAssertNil(payload.makeItemProvider())
    }
}
