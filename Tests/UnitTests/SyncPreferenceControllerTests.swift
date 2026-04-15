@testable import ClipKitty
import Combine
import XCTest

@MainActor
final class SyncPreferenceControllerTests: XCTestCase {
    func testBindAppliesInitialValue() async {
        let changes = PassthroughSubject<Bool, Never>()
        var appliedValues: [Bool] = []
        var registerCalls = 0

        let controller = SyncPreferenceController(
            applySyncEnabled: { appliedValues.append($0) },
            registerForRemoteNotifications: { registerCalls += 1 }
        )

        controller.bind(initialValue: true, changes: changes)
        // Changes are applied via an async hop so SwiftUI can render the
        // toggle state before CloudKit bootstrap blocks main.
        await Task.yield()

        XCTAssertEqual(appliedValues, [true])
        XCTAssertEqual(registerCalls, 1)
    }

    func testBindDeduplicatesChangesAndOnlyRegistersWhenEnabling() async {
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
        // Drain all scheduled hops before asserting.
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        XCTAssertEqual(appliedValues, [false, true, false, true])
        XCTAssertEqual(registerCalls, 2)
    }
}
