@testable import ClipKittyiOS
import XCTest

final class OnboardingFlowTests: XCTestCase {
    /// Advancing from the first page must reach the last one without gaps, and
    /// only the last page ends the flow.
    func testPagesFormOneChainEndingAtPasteAccess() {
        var visited: [OnboardingPage] = [.welcome]
        var page = OnboardingPage.welcome
        while let next = page.next {
            visited.append(next)
            page = next
            XCTAssertLessThanOrEqual(
                visited.count,
                OnboardingPage.allCases.count,
                "onboarding pages form a cycle"
            )
        }
        XCTAssertEqual(visited.count, OnboardingPage.allCases.count)
        XCTAssertEqual(page, .pasteAccess)
    }

    /// Back navigation has to retrace the same chain, so the back button never
    /// skips a page or strands the user.
    func testPreviousIsTheInverseOfNext() {
        for page in OnboardingPage.allCases {
            switch page.next {
            case let .some(next):
                XCTAssertEqual(next.previous, page)
            case .none:
                XCTAssertEqual(page, .pasteAccess)
            }
        }
    }

    /// Only the first page hides its back button.
    func testOnlyWelcomeHasNoPreviousPage() {
        XCTAssertNil(OnboardingPage.welcome.previous)
        for page in OnboardingPage.allCases where page != .welcome {
            XCTAssertNotNil(page.previous)
        }
    }

    /// Both permission states render the permission page beneath their sheet,
    /// so the page does not blank out while the probe or instructions are up.
    func testPasteAccessStatesRemainOnThePermissionPage() {
        XCTAssertEqual(OnboardingFlowState.probingPasteAccess.visiblePage, .pasteAccess)
        XCTAssertEqual(OnboardingFlowState.explainingPasteAccess.visiblePage, .pasteAccess)
        for page in OnboardingPage.allCases {
            XCTAssertEqual(OnboardingFlowState.page(page).visiblePage, page)
        }
    }
}
