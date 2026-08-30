@testable import ClipKittyiOS
import ClipKittyRust
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class PasteboardItemEncoderTests: XCTestCase {
    func testTransferItemCountBoundaries() {
        XCTAssertEqual(iOSTransferLimits.validateItemCount(0), .tooManyItems)
        XCTAssertNil(iOSTransferLimits.validateItemCount(1))
        XCTAssertNil(iOSTransferLimits.validateItemCount(50))
        XCTAssertEqual(iOSTransferLimits.validateItemCount(51), .tooManyItems)
    }

    func testTextAndImagePayloadBoundaries() {
        let maximumText = String(
            repeating: "a",
            count: iOSTransferLimits.maximumTextByteCount
        )
        XCTAssertEqual(
            try? iOSTransferLimits.payloadByteCount(.text(value: maximumText)).get(),
            iOSTransferLimits.maximumTextByteCount
        )
        XCTAssertEqual(
            iOSTransferLimits.payloadByteCount(.text(value: maximumText + "a")),
            .failure(.itemTooLarge)
        )

        let fourByteCharacter = "🐈"
        XCTAssertEqual(
            try? iOSTransferLimits.payloadByteCount(.text(value: fourByteCharacter)).get(),
            4
        )

        let maximumImage = Data(count: iOSTransferLimits.maximumImageByteCount)
        XCTAssertEqual(
            try? iOSTransferLimits.payloadByteCount(
                .image(data: maximumImage, description: "", isAnimated: false)
            ).get(),
            iOSTransferLimits.maximumImageByteCount
        )
        XCTAssertEqual(
            iOSTransferLimits.payloadByteCount(
                .image(
                    data: Data(count: iOSTransferLimits.maximumImageByteCount + 1),
                    description: "",
                    isAnimated: false
                )
            ),
            .failure(.itemTooLarge)
        )
    }

    func testAggregateLimitIsExactAndOverflowSafe() {
        XCTAssertEqual(
            try? iOSTransferLimits.adding(
                iOSTransferLimits.maximumAggregateByteCount,
                to: 0
            ).get(),
            iOSTransferLimits.maximumAggregateByteCount
        )
        XCTAssertEqual(
            iOSTransferLimits.adding(
                1,
                to: iOSTransferLimits.maximumAggregateByteCount
            ),
            .failure(.aggregateTooLarge)
        )
        XCTAssertEqual(
            iOSTransferLimits.adding(Int.max, to: Int.max),
            .failure(.aggregateTooLarge)
        )
    }

    func testBatchEncoderRejectsMoreThanFiftyItems() async {
        let contents = (0 ... iOSTransferLimits.maximumItemCount).map { index in
            ClipboardContent.text(value: "item-\(index)")
        }

        let result = await PasteboardItemEncoder.prepareAll(contents)
        XCTAssertNil(result)
    }

    func testTextAndColorEncodeAsPlainText() async throws {
        let text = try await encodedItem(for: .text(value: "hello"))
        let color = try await encodedItem(for: .color(value: "#C0FFEE"))

        XCTAssertEqual(text[UTType.utf8PlainText.identifier] as? String, "hello")
        XCTAssertEqual(color[UTType.utf8PlainText.identifier] as? String, "#C0FFEE")
    }

    func testLinkCarriesURLAndPlainTextFallback() async throws {
        let value = "https://example.com/path"
        let item = try await encodedItem(for: .link(url: value, metadataState: .pending))

        XCTAssertEqual((item[UTType.url.identifier] as? NSURL)?.absoluteString, value)
        XCTAssertEqual(item[UTType.utf8PlainText.identifier] as? String, value)
    }

    func testInvalidLinkStillCarriesItsStoredText() async throws {
        let value = "not a valid URL"
        let item = try await encodedItem(for: .link(url: value, metadataState: .pending))

        XCTAssertNil(item[UTType.url.identifier])
        XCTAssertEqual(item[UTType.utf8PlainText.identifier] as? String, value)
    }

    func testImagePreservesItsNativeRepresentation() async throws {
        let png = try XCTUnwrap(Self.onePixelPNG)
        let item = try await encodedItem(
            for: .image(data: png, description: "pixel", isAnimated: false)
        )

        XCTAssertEqual(item[UTType.png.identifier] as? Data, png)
    }

    func testPhotoImportPreparationBuildsThumbnailAndPreservesAnimation() async throws {
        let png = try XCTUnwrap(Self.onePixelPNG)
        let preparedPNG = await PhotoImportImagePreparer.prepare(png)
        let pngAnalysis = try XCTUnwrap(preparedPNG)
        XCTAssertNotNil(pngAnalysis.thumbnail)
        XCTAssertFalse(pngAnalysis.isAnimated)

        let gif = try Self.makeAnimatedGIF()
        let preparedGIF = await PhotoImportImagePreparer.prepare(gif)
        let gifAnalysis = try XCTUnwrap(preparedGIF)
        XCTAssertNotNil(gifAnalysis.thumbnail)
        XCTAssertTrue(gifAnalysis.isAnimated)
    }

    func testPhotoImportPreparationRejectsOversizedBytes() async {
        let data = Data(count: iOSTransferLimits.maximumImageByteCount + 1)
        let result = await PhotoImportImagePreparer.prepare(data)

        XCTAssertNil(result)
    }

    func testPhotoImportPreparationDiscardsInspectionResultAfterCancellation() async throws {
        let png = try XCTUnwrap(Self.onePixelPNG)
        let inspectionStarted = expectation(description: "inspection started")
        let task = Task {
            await PhotoImportImagePreparer.prepare(png) { _ in
                inspectionStarted.fulfill()
                try? await Task.sleep(for: .seconds(30))
                return PasteboardImageAnalysis(thumbnail: Data([0x01]), isAnimated: false)
            }
        }
        await fulfillment(of: [inspectionStarted], timeout: 1)

        task.cancel()
        let result = await task.value

        XCTAssertNil(result)
    }

    func testBatchEncodingIsAtomic() async {
        let result = await PasteboardItemEncoder.prepareAll([
            .text(value: "first"),
            .image(data: Data(), description: "bad", isAnimated: false),
            .text(value: "third"),
        ])

        XCTAssertNil(result)
    }

    func testTruncatedPNGHeaderIsRejectedEvenThoughImageIOIdentifiesIt() async throws {
        let complete = try XCTUnwrap(Self.onePixelPNG)
        let truncated = Data(complete.prefix(20))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(truncated as CFData, nil))

        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        XCTAssertNil(TransferImageValidator.nativeTypeIdentifier(for: truncated))
        XCTAssertNil(DragItemProvider.nativeImageTypeIdentifier(for: truncated))
        let photoImport = await PhotoImportImagePreparer.prepare(truncated)
        XCTAssertNil(photoImport)

        let result = await PasteboardItemEncoder.prepareAll([
            .image(data: truncated, description: "truncated", isAnimated: false),
        ])
        XCTAssertNil(result)
    }

    func testExcessivePixelDimensionIsRejectedBeforeOutboundTransfer() async throws {
        let data = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgABhqAAAAABAQAAAAB1BSt4AAAAI0lEQVR42u3BMQEAAADCoPVPbQwfoAAAAAAAAAAAAAAAAA4GMNUAAcmPjhAAAAAASUVORK5CYII="))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )

        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 100_000)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 1)
        XCTAssertNil(TransferImageValidator.nativeTypeIdentifier(for: data))
        XCTAssertNil(DragItemProvider.nativeImageTypeIdentifier(for: data))
        let photoImport = await PhotoImportImagePreparer.prepare(data)
        XCTAssertNil(photoImport)

        let result = await PasteboardItemEncoder.prepareAll([
            .image(data: data, description: "too wide", isAnimated: false),
        ])
        XCTAssertNil(result)
    }

    private func encodedItem(for content: ClipboardContent) async throws -> [String: Any] {
        let batch = await PasteboardItemEncoder.prepareAll([content])
        return try XCTUnwrap(batch?.pasteboardItems.first)
    }

    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")

    private static func makeAnimatedGIF() throws -> Data {
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output,
            UTType.gif.identifier as CFString,
            2,
            nil
        ))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        func frame(red: UInt8, blue: UInt8) throws -> CGImage {
            var pixel = [red, 0, blue, 255]
            return try pixel.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(
                    data: bytes.baseAddress,
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: 4,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                ))
                return try XCTUnwrap(context.makeImage())
            }
        }

        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: 0.1,
            ],
        ]
        try CGImageDestinationAddImage(
            destination,
            frame(red: 255, blue: 0),
            frameProperties as CFDictionary
        )
        try CGImageDestinationAddImage(
            destination,
            frame(red: 0, blue: 255),
            frameProperties as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
