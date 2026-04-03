@testable import ClipKittyiOS
import XCTest

@MainActor
final class SceneStateTests: XCTestCase {
    private var tempDir: URL!
    private var container: AppContainer!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty-scene-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("test.db").path
        guard case let .success(c) = AppContainer.bootstrap(databasePath: dbPath) else {
            XCTFail("Bootstrap failed")
            return
        }
        container = c
    }

    override func tearDown() {
        container = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Scene State Isolation

    func testModalRouteIsIndependentPerScene() {
        let scene1 = SceneState(container: container)
        let scene2 = SceneState(container: container)

        scene1.modalRoute = .settings

        XCTAssertEqual(scene1.modalRoute, .settings)
        XCTAssertNil(scene2.modalRoute)
    }

    func testChromeStateIsIndependentPerScene() {
        let scene1 = SceneState(container: container)
        let scene2 = SceneState(container: container)

        scene1.chromeState = .searching

        XCTAssertEqual(scene1.chromeState, .searching)
        XCTAssertEqual(scene2.chromeState, .idle)
    }

    func testDetailSelectionIsIndependentPerScene() {
        let scene1 = SceneState(container: container)
        let scene2 = SceneState(container: container)

        scene1.detailSelection = .selected(itemId: "abc-123")

        XCTAssertEqual(scene1.detailSelection, .selected(itemId: "abc-123"))
        XCTAssertEqual(scene2.detailSelection, .none)
    }

    func testToastStateIsIndependentPerScene() {
        let scene1 = SceneState(container: container)
        let scene2 = SceneState(container: container)

        scene1.toast = SceneState.ToastState(message: .copied, action: nil)

        XCTAssertEqual(scene1.toast.message, .copied)
        XCTAssertNil(scene2.toast.message)
    }

    // MARK: - Deep Link Routing

    func testSearchDeepLinkClearsModalAndSetsSearching() {
        let scene = SceneState(container: container)
        scene.modalRoute = .settings

        // Simulate receiving a search deep link and consuming it.
        scene.router.handle(.search(query: "hello"))
        let link = scene.router.consumeDeepLink()

        // After consuming, apply the deep link effect.
        if case .search = link {
            scene.modalRoute = nil
            scene.chromeState = .searching
        }

        XCTAssertNil(scene.modalRoute)
        XCTAssertEqual(scene.chromeState, .searching)
    }

    // MARK: - AppRouter Deep Link Parsing

    func testHandleURLParsesSearchDeepLink() {
        let router = AppRouter()

        router.handleURL(URL(string: "clipkitty://search?q=hello")!)

        XCTAssertEqual(router.pendingDeepLink, .search(query: "hello"))
    }

    func testHandleURLParsesAddDeepLink() {
        let router = AppRouter()

        router.handleURL(URL(string: "clipkitty://add")!)

        XCTAssertEqual(router.pendingDeepLink, .newItem)
    }

    func testHandleURLIgnoresUnknownScheme() {
        let router = AppRouter()

        router.handleURL(URL(string: "https://example.com/search?q=hello")!)

        XCTAssertNil(router.pendingDeepLink)
    }

    func testHandleURLIgnoresUnknownHost() {
        let router = AppRouter()

        router.handleURL(URL(string: "clipkitty://unknown")!)

        XCTAssertNil(router.pendingDeepLink)
    }

    func testHandleURLSearchWithoutQueryDefaultsToEmpty() {
        let router = AppRouter()

        router.handleURL(URL(string: "clipkitty://search")!)

        XCTAssertEqual(router.pendingDeepLink, .search(query: ""))
    }

    func testConsumeDeepLinkClearsPending() {
        let router = AppRouter()
        router.handle(.newItem)

        let consumed = router.consumeDeepLink()

        XCTAssertEqual(consumed, .newItem)
        XCTAssertNil(router.pendingDeepLink)
    }
}
