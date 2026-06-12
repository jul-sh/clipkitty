import ClipKittyShared
import XCTest

final class StorageLimitScaleTests: XCTestCase {
    private let scale = StorageLimitScale()

    func testEndpointPositions() {
        XCTAssertEqual(scale.position(forGB: 0.5), 0, accuracy: 1e-9)
        XCTAssertEqual(scale.position(forGB: 64), 1, accuracy: 1e-9)
    }

    func testPositionClampsOutOfRangeSizes() {
        XCTAssertEqual(scale.position(forGB: 0.1), 0, accuracy: 1e-9)
        XCTAssertEqual(scale.position(forGB: 500), 1, accuracy: 1e-9)
    }

    func testPositionIsMonotonic() {
        let positions = [0.5, 0.8, 1.0, 2.0, 7.0, 16.0, 64.0].map { scale.position(forGB: $0) }
        XCTAssertEqual(positions, positions.sorted())
    }

    func testRoundTripForCleanSizes() {
        for gb in [0.5, 0.7, 1.0, 2.0, 7.0, 16.0, 64.0] {
            XCTAssertEqual(scale.gb(forPosition: scale.position(forGB: gb)), gb, accuracy: 1e-9)
        }
    }

    func testPositionsRoundToCleanSizes() {
        XCTAssertEqual(scale.gb(forPosition: 0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(scale.gb(forPosition: 1), 64, accuracy: 1e-9)

        // From 1 GB up, values round to whole gigabytes.
        let large = scale.gb(forPosition: 0.6)
        XCTAssertGreaterThanOrEqual(large, 1)
        XCTAssertEqual(large, large.rounded(), accuracy: 1e-9)

        // Below 1 GB, values round to tenths.
        let small = scale.gb(forPosition: 0.05)
        XCTAssertLessThan(small, 1)
        XCTAssertEqual(small * 10, (small * 10).rounded(), accuracy: 1e-9)
    }

    func testGBClampsOutOfRangePositions() {
        XCTAssertEqual(scale.gb(forPosition: -0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(scale.gb(forPosition: 1.5), 64, accuracy: 1e-9)
    }

    func testAdjustingUsesWholeGigabyteStepsFromOneUp() {
        XCTAssertEqual(scale.adjusting(7, by: 1), 8, accuracy: 1e-9)
        XCTAssertEqual(scale.adjusting(7, by: -1), 6, accuracy: 1e-9)
        XCTAssertEqual(scale.adjusting(1, by: 1), 2, accuracy: 1e-9)
    }

    func testAdjustingUsesTenthStepsBelowOneGigabyte() {
        XCTAssertEqual(scale.adjusting(0.5, by: 1), 0.6, accuracy: 1e-9)
        XCTAssertEqual(scale.adjusting(1, by: -1), 0.9, accuracy: 1e-9)
        XCTAssertEqual(scale.adjusting(0.9, by: 1), 1.0, accuracy: 1e-9)
    }

    func testAdjustingClampsAtRangeEnds() {
        XCTAssertEqual(scale.adjusting(64, by: 1), 64, accuracy: 1e-9)
        XCTAssertEqual(scale.adjusting(0.5, by: -1), 0.5, accuracy: 1e-9)
    }

    func testBytesFromGB() {
        XCTAssertEqual(Utilities.bytes(fromGB: 1), 1_073_741_824)
        XCTAssertEqual(Utilities.bytes(fromGB: 0.5), 536_870_912)
        XCTAssertEqual(Utilities.bytes(fromGB: 7), 7_516_192_768)
    }
}
