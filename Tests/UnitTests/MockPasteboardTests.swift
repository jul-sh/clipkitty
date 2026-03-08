import XCTest
import AppKit

/// Tests for MockPasteboard to ensure it correctly mimics NSPasteboard behavior.
/// These tests verify the mock infrastructure works before using it in other tests.
final class MockPasteboardTests: XCTestCase {

    // MARK: - Basic Operations

    func testInitialState() {
        let pasteboard = MockPasteboard()

        XCTAssertEqual(pasteboard.changeCount, 0)
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertNil(pasteboard.data(forType: .tiff))
        XCTAssertTrue(pasteboard.types()?.isEmpty ?? true)
    }

    func testSetString() {
        let pasteboard = MockPasteboard()

        let result = pasteboard.setString("Hello, World!", forType: .string)

        XCTAssertTrue(result)
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello, World!")
        XCTAssertEqual(pasteboard.changeCount, 1)
    }

    func testSetData() {
        let pasteboard = MockPasteboard()
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])

        let result = pasteboard.setData(data, forType: .tiff)

        XCTAssertTrue(result)
        XCTAssertEqual(pasteboard.data(forType: .tiff), data)
        XCTAssertEqual(pasteboard.changeCount, 1)
    }

    func testSetNilData() {
        let pasteboard = MockPasteboard()
        let data = Data([1, 2, 3])
        pasteboard.setData(data, forType: .tiff)

        pasteboard.setData(nil, forType: .tiff)

        XCTAssertNil(pasteboard.data(forType: .tiff))
        XCTAssertEqual(pasteboard.changeCount, 2)
    }

    func testClearContents() {
        let pasteboard = MockPasteboard()
        pasteboard.setString("test", forType: .string)
        pasteboard.setData(Data([1, 2, 3]), forType: .tiff)
        let initialCount = pasteboard.changeCount

        let newCount = pasteboard.clearContents()

        XCTAssertEqual(newCount, initialCount + 1)
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertNil(pasteboard.data(forType: .tiff))
    }

    func testDeclareTypes() {
        let pasteboard = MockPasteboard()

        let count = pasteboard.declareTypes([.string, .tiff], owner: nil)

        XCTAssertGreaterThan(count, 0)
        XCTAssertEqual(pasteboard.types(), [.string, .tiff])
    }

    func testSetPropertyList() {
        let pasteboard = MockPasteboard()
        let paths = ["/path/to/file1.txt", "/path/to/file2.txt"]
        let filenameType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

        let result = pasteboard.setPropertyList(paths, forType: filenameType)

        XCTAssertTrue(result)
        let retrieved = pasteboard.propertyList(forType: filenameType) as? [String]
        XCTAssertEqual(retrieved, paths)
    }

    // MARK: - Change Count Tracking

    func testChangeCountIncrementsOnEachOperation() {
        let pasteboard = MockPasteboard()
        XCTAssertEqual(pasteboard.changeCount, 0)

        pasteboard.setString("1", forType: .string)
        XCTAssertEqual(pasteboard.changeCount, 1)

        pasteboard.setString("2", forType: .string)
        XCTAssertEqual(pasteboard.changeCount, 2)

        pasteboard.clearContents()
        XCTAssertEqual(pasteboard.changeCount, 3)
    }

    // MARK: - Test Helper Methods

    func testSimulateExternalChange() {
        let pasteboard = MockPasteboard()
        let initialCount = pasteboard.changeCount

        pasteboard.simulateExternalChange(string: "External clipboard content")

        XCTAssertEqual(pasteboard.string(forType: .string), "External clipboard content")
        XCTAssertEqual(pasteboard.changeCount, initialCount + 1)
    }

    func testReset() {
        let pasteboard = MockPasteboard()
        pasteboard.setString("test", forType: .string)
        pasteboard.setData(Data([1, 2, 3]), forType: .tiff)
        pasteboard.declareTypes([.string, .fileURL], owner: nil)

        pasteboard.reset()

        XCTAssertEqual(pasteboard.changeCount, 0)
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertNil(pasteboard.data(forType: .tiff))
        XCTAssertTrue(pasteboard.types()?.isEmpty ?? true)
    }

    // MARK: - Multiple Types

    func testMultipleTypesCoexist() {
        let pasteboard = MockPasteboard()

        pasteboard.setString("text", forType: .string)
        pasteboard.setString("https://example.com", forType: .fileURL)
        pasteboard.setData(Data([1, 2, 3]), forType: .tiff)

        XCTAssertEqual(pasteboard.string(forType: .string), "text")
        XCTAssertEqual(pasteboard.string(forType: .fileURL), "https://example.com")
        XCTAssertEqual(pasteboard.data(forType: .tiff), Data([1, 2, 3]))
    }

    func testTypesReturnsStoredKeys() {
        let pasteboard = MockPasteboard()
        pasteboard.setString("text", forType: .string)
        pasteboard.setData(Data([1]), forType: .tiff)

        let types = pasteboard.types()

        XCTAssertNotNil(types)
        XCTAssertTrue(types!.contains(.string))
        XCTAssertTrue(types!.contains(.tiff))
    }

    // MARK: - Protocol Conformance

    func testProtocolConformance() {
        // Verify MockPasteboard can be used where PasteboardProtocol is expected
        let pasteboard: PasteboardProtocol = MockPasteboard()

        pasteboard.clearContents()
        _ = pasteboard.setString("test", forType: .string)

        XCTAssertEqual(pasteboard.string(forType: .string), "test")
        XCTAssertGreaterThan(pasteboard.changeCount, 0)
    }

    func testNSPasteboardConformance() {
        // Verify NSPasteboard also conforms to PasteboardProtocol
        let _: PasteboardProtocol = NSPasteboard.general

        // This is a compile-time check - if it compiles, the conformance works
        XCTAssertTrue(true)
    }
}
