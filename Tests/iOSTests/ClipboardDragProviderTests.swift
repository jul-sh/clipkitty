@testable import ClipKittyiOS
import ClipKittyRust
import UniformTypeIdentifiers
import XCTest

@MainActor
final class ClipboardDragProviderTests: XCTestCase {
    // MARK: - Provider Creation

    func testTextMetadataCreatesProvider() {
        let metadata = ItemMetadata.stub(icon: .symbol(iconType: .text))
        let provider = ClipboardDragProviderFactory.makeProvider(
            metadata: metadata,
            fetch: { nil }
        )
        XCTAssertNotNil(provider)
    }

    func testLinkMetadataCreatesProvider() {
        let metadata = ItemMetadata.stub(icon: .symbol(iconType: .link))
        let provider = ClipboardDragProviderFactory.makeProvider(
            metadata: metadata,
            fetch: { nil }
        )
        XCTAssertNotNil(provider)
    }

    func testImageMetadataCreatesProvider() {
        let metadata = ItemMetadata.stub(icon: .symbol(iconType: .image))
        let provider = ClipboardDragProviderFactory.makeProvider(
            metadata: metadata,
            fetch: { nil }
        )
        XCTAssertNotNil(provider)
    }

    func testFileMetadataReturnsNil() {
        let metadata = ItemMetadata.stub(icon: .symbol(iconType: .file))
        let provider = ClipboardDragProviderFactory.makeProvider(
            metadata: metadata,
            fetch: { nil }
        )
        XCTAssertNil(provider)
    }

    func testColorSwatchMetadataCreatesProvider() {
        let metadata = ItemMetadata.stub(icon: .colorSwatch(rgba: 0xFF00_00FF))
        let provider = ClipboardDragProviderFactory.makeProvider(
            metadata: metadata,
            fetch: { nil }
        )
        XCTAssertNotNil(provider)
    }

    func testThumbnailMetadataCreatesProvider() {
        let metadata = ItemMetadata.stub(icon: .thumbnail(bytes: Data([0x89, 0x50])))
        let provider = ClipboardDragProviderFactory.makeProvider(
            metadata: metadata,
            fetch: { nil }
        )
        XCTAssertNotNil(provider)
    }

    // MARK: - Advertised Representations

    func testTextProviderAdvertisesPlainText() {
        let metadata = ItemMetadata.stub(icon: .symbol(iconType: .text))
        let provider = ClipboardDragProviderFactory.makeProvider(
            metadata: metadata,
            fetch: { nil }
        )
        XCTAssertTrue(provider?.registeredContentTypes.contains(UTType.plainText) ?? false)
    }

    func testLinkProviderAdvertisesURLAndPlainText() {
        let metadata = ItemMetadata.stub(icon: .symbol(iconType: .link))
        let provider = ClipboardDragProviderFactory.makeProvider(
            metadata: metadata,
            fetch: { nil }
        )
        let types: [UTType] = provider?.registeredContentTypes ?? []
        XCTAssertTrue(types.contains(UTType.url))
        XCTAssertTrue(types.contains(UTType.plainText))
    }

    func testImageProviderAdvertisesImage() {
        let metadata = ItemMetadata.stub(icon: .symbol(iconType: .image))
        let provider = ClipboardDragProviderFactory.makeProvider(
            metadata: metadata,
            fetch: { nil }
        )
        let types: [UTType] = provider?.registeredContentTypes ?? []
        XCTAssertTrue(types.contains(UTType.image))
    }

    // MARK: - Lazy Fetch

    func testProviderFetchesItemOnlyOnce() async {
        var fetchCount = 0
        let metadata = ItemMetadata.stub(icon: .symbol(iconType: .text))
        let item = ClipboardItem(
            itemMetadata: metadata,
            content: .text(value: "hello")
        )

        let provider = ClipboardDragProviderFactory.makeProvider(
            metadata: metadata,
            fetch: {
                fetchCount += 1
                return item
            }
        )
        XCTAssertNotNil(provider)

        // Load data twice — fetch should only happen once
        let expectation1 = XCTestExpectation(description: "First load")
        let expectation2 = XCTestExpectation(description: "Second load")

        provider?.loadDataRepresentation(for: UTType.plainText) { data, error in
            XCTAssertNotNil(data)
            XCTAssertNil(error)
            expectation1.fulfill()
        }

        provider?.loadDataRepresentation(for: UTType.plainText) { data, error in
            XCTAssertNotNil(data)
            XCTAssertNil(error)
            expectation2.fulfill()
        }

        await fulfillment(of: [expectation1, expectation2], timeout: 5)
        XCTAssertEqual(fetchCount, 1)
    }

    // MARK: - Fetch Failure

    func testProviderHandlesFetchFailureGracefully() async {
        let metadata = ItemMetadata.stub(icon: .symbol(iconType: .text))
        let provider = ClipboardDragProviderFactory.makeProvider(
            metadata: metadata,
            fetch: { nil }
        )
        XCTAssertNotNil(provider)

        let expectation = XCTestExpectation(description: "Load completes")
        provider?.loadDataRepresentation(for: UTType.plainText) { data, error in
            XCTAssertNil(data)
            XCTAssertNotNil(error)
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 5)
    }
}

// MARK: - Test Helpers

private extension ItemMetadata {
    static func stub(
        icon: ItemIcon,
        itemId: String = "test-id"
    ) -> ItemMetadata {
        ItemMetadata(
            itemId: itemId,
            icon: icon,
            snippet: "test snippet",
            sourceApp: nil,
            sourceAppBundleId: nil,
            timestampUnix: Int64(Date().timeIntervalSince1970),
            tags: []
        )
    }
}
