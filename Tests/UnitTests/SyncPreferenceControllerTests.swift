@testable import ClipKitty
import Combine
import XCTest

@MainActor
final class SyncPreferenceControllerTests: XCTestCase {
    func testBindAppliesInitialValue() {
        let changes = PassthroughSubject<Bool, Never>()
        var appliedValues: [Bool] = []
        var registerCalls = 0

        let controller = SyncPreferenceController(
            applySyncEnabled: { appliedValues.append($0) },
            registerForRemoteNotifications: { registerCalls += 1 }
        )

        controller.bind(initialValue: true, changes: changes)

        XCTAssertEqual(appliedValues, [true])
        XCTAssertEqual(registerCalls, 1)
    }

    func testBindDeduplicatesChangesAndOnlyRegistersWhenEnabling() {
        let changes = PassthroughSubject<Bool, Never>()
        var appliedValues: [Bool] = []
        var registerCalls = 0

        let controller = SyncPreferenceController(
            applySyncEnabled: { appliedValues.append($0) },
            registerForRemoteNotifications: { registerCalls += 1 }
        )

        controller.bind(initialValue: false, changes: changes)
        changes.send(false)
        changes.send(true)
        changes.send(true)
        changes.send(false)
        changes.send(true)

        XCTAssertEqual(appliedValues, [false, true, false, true])
        XCTAssertEqual(registerCalls, 2)
    }
}
