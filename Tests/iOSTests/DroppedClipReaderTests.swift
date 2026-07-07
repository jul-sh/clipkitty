@testable import ClipKittyiOS
import UIKit
import UniformTypeIdentifiers
import XCTest

/// Exercises the drop-to-add classification with synthetic providers shaped
/// like the ones UIKit hands over for real drags: plain text, web URLs, file
/// URLs, image data, and ClipKitty's own marked card drags.
@MainActor
final class DroppedClipReaderTests: XCTestCase {
    func testPlainTextLoadsAsText() async {
        let provider = NSItemProvider(object: "hello clip" as NSString)
        let payload = await DroppedClipReader.load(from: provider)
        XCTAssertEqual(payload, .text("hello clip"))
    }

    func testWhitespaceOnlyTextIsDeclined() async {
        let provider = NSItemProvider(object: "  \n " as NSString)
        let payload = await DroppedClipReader.load(from: provider)
        XCTAssertNil(payload)
    }

    func testWebURLLoadsAsURL() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/kitty"))
        let provider = NSItemProvider(object: url as NSURL)
        let payload = await DroppedClipReader.load(from: provider)
        XCTAssertEqual(payload, .url(url))
    }

    func testFileURLIsDeclined() async {
        let provider = NSItemProvider(object: URL(fileURLWithPath: "/tmp/notes.txt") as NSURL)
        let payload = await DroppedClipReader.load(from: provider)
        XCTAssertNil(payload)
    }

    func testImageDataLoadsAsImageAndBeatsText() async {
        let pngData = Self.tinyPNG()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(pngData, nil)
            return nil
        }
        // Real image drags often carry a text fallback too; the image must win.
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            completion(Data("fallback".utf8), nil)
            return nil
        }
        let payload = await DroppedClipReader.load(from: provider)
        XCTAssertEqual(payload, .image(data: pngData, isAnimated: false))
    }

    func testGIFIsMarkedAnimated() async {
        let gifData = Data("GIF89a-stub".utf8)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.gif.identifier, visibility: .all) { completion in
            completion(gifData, nil)
            return nil
        }
        let payload = await DroppedClipReader.load(from: provider)
        XCTAssertEqual(payload, .image(data: gifData, isAnimated: true))
    }

    func testInternalCardDragIsRecognized() {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: DragItemProvider.internalDragMarker,
            visibility: .ownProcess
        ) { completion in
            completion(Data(), nil)
            return nil
        }
        XCTAssertTrue(DroppedClipReader.isInternalDrag(provider))
        XCTAssertFalse(DroppedClipReader.isInternalDrag(NSItemProvider(object: "text" as NSString)))
    }

    func testCardDragProviderCarriesInternalMarker() {
        let provider = DragItemProvider.make(itemId: "item-1") { _ in nil }
        XCTAssertTrue(DroppedClipReader.isInternalDrag(provider))
    }

    /// A 1x1 opaque PNG rendered at runtime, so the test needs no fixture.
    private static func tinyPNG() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let image = renderer.image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return image.pngData() ?? Data()
    }
}
