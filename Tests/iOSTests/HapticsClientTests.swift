@testable import ClipKittyiOS
import XCTest

@MainActor
final class HapticsClientTests: XCTestCase {
    func testFireDoesNotCrash() {
        let client = HapticsClient()
        client.fire(.copy)
        client.fire(.selection)
        client.fire(.success)
        client.fire(.destructive)
    }
}
