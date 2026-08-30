@testable import ClipKittyiOS
import XCTest

@MainActor
final class DockedKeyboardInsetTests: XCTestCase {
    func testNoKeyboardUsesNoExtraInset() {
        XCTAssertEqual(
            DockedKeyboardInsetCalculator.bottomInset(
                safeAreaMaxY: 1000,
                keyboardGuideMinY: 1000
            ),
            0
        )
    }

    func testDockedKeyboardUsesSpaceAboveItsGuide() {
        XCTAssertEqual(
            DockedKeyboardInsetCalculator.bottomInset(
                safeAreaMaxY: 1000,
                keyboardGuideMinY: 640
            ),
            360
        )
    }

    func testFloatingAndUndockedKeyboardGuideUsesNoExtraInset() {
        // With followsUndockedKeyboard disabled, UIKit ties this guide to the
        // normal safe-area bottom for floating, split, and undocked keyboards.
        XCTAssertEqual(
            DockedKeyboardInsetCalculator.bottomInset(
                safeAreaMaxY: 1000,
                keyboardGuideMinY: 1000
            ),
            0
        )
    }

    func testGuideBelowSafeAreaDoesNotProduceNegativeInset() {
        XCTAssertEqual(
            DockedKeyboardInsetCalculator.bottomInset(
                safeAreaMaxY: 800,
                keyboardGuideMinY: 820
            ),
            0
        )
    }

    func testNonFiniteGeometryIsIgnored() {
        XCTAssertEqual(
            DockedKeyboardInsetCalculator.bottomInset(
                safeAreaMaxY: .nan,
                keyboardGuideMinY: 600
            ),
            0
        )
        XCTAssertEqual(
            DockedKeyboardInsetCalculator.bottomInset(
                safeAreaMaxY: 800,
                keyboardGuideMinY: .infinity
            ),
            0
        )
    }
}
