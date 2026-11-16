import XCTest

/// Marketing screenshot generator for the iOS App Store listing.
///
/// Captures four screenshots on iPhone 17, iPhone 17 Pro Max, iPhone Duo
/// (outer display, 1398x2034; ASC's APP_IPHONE_DUO slot), or iPad Pro
/// 13-inch M5. The scenes are identical across devices; the simulator
/// chosen by the xcodebuild destination and output filename stem differ.
///   1. History feed; the main clipboard history view
///   2. Search; search bar active with a query
///   3. Filter; filtered by a content type
///   4. Share; the system share sheet over a clip card
///
/// Locale is read from `/tmp/clipkitty_ios_screenshot_locale.txt`.
/// Database filename is read from `/tmp/clipkitty_ios_screenshot_db.txt`.
/// Device kind (`iphone`, `iphone-duo`, or `ipad`) is read from
/// `/tmp/clipkitty_ios_screenshot_device.txt` and picks the output
/// filename prefix so back-to-back iPhone and iPad runs don't overwrite
/// each other's PNGs.
/// Screenshots are written to
/// `/tmp/clipkitty_{ios|ios-duo|ipad}_[{locale}_]marketing_{n}_{name}.png`
/// (the locale segment is omitted for English, matching the existing
/// iPhone behaviour).
final class ClipKittyiOSScreenshotTests: XCTestCase {
    private enum DeviceKind: String {
        case iPhone = "iphone"
        case iPhoneDuo = "iphone-duo"
        case iPad = "ipad"

        var filenameStem: String {
            switch self {
            case .iPhone: return "ios"
            case .iPhoneDuo: return "ios-duo"
            case .iPad: return "ipad"
            }
        }
    }

    private var app: XCUIApplication!
    private var locale: String!
    private var deviceKind: DeviceKind = .iPhone

    private static let localeConfigFile = "clipkitty_ios_screenshot_locale.txt"
    private static let dbConfigFile = "clipkitty_ios_screenshot_db.txt"
    private static let deviceConfigFile = "clipkitty_ios_screenshot_device.txt"

    override func setUpWithError() throws {
        continueAfterFailure = false

        locale = readTempConfig(Self.localeConfigFile, defaultValue: "en") ?? "en"
        let deviceToken = readTempConfig(Self.deviceConfigFile, defaultValue: "iphone") ?? "iphone"
        deviceKind = try XCTUnwrap(DeviceKind(rawValue: deviceToken), "Unknown screenshot device kind")
        XCUIDevice.shared.orientation = .portrait

        let screenshotDBPath = try setupTestDatabase()

        app = XCUIApplication()
        app.launchEnvironment["CLIPKITTY_SCREENSHOT_DB"] = screenshotDBPath

        // Set the UI language for this locale
        app.launchArguments += ["-AppleLanguages", "(\(locale!))"]
        app.launchArguments += ["-AppleLocale", locale]
        // Marketing scenes always start with the complete history, regardless
        // of the category remembered from an earlier run on this simulator.
        app.launchArguments += ["-iOSLastSelectedCategory", "all"]
        // Marketing captures must not show the clipboard-permission card that
        // tops the feed until the user dismisses it or finishes its
        // allow-access flow. The plist literal matters: a bare "YES" reaches
        // the argument domain as a string, and the settings store's
        // `object(forKey:) as? Bool` read ignores it.
        app.launchArguments += ["-iOSPermissionHintDismissed", "<true/>"]
        app.launch()

        // Let the feed mount and the visible cards kick off their image
        // fetch/decode tasks (the settled signal below can only be trusted
        // once loading has actually started), then wait for the app to report
        // every in-flight image load finished. The signal-based wait replaced
        // fixed sleeps because no guessed duration survived a loaded CI
        // runner: 8s and 15s settles both shipped placeholder cards to the
        // App Store (runs 28795788433 and the iPhone follow-up).
        sleep(3)
        waitForFeedSettled(context: "initial feed")
    }

    override func tearDownWithError() throws {
        if let run = testRun, run.totalFailureCount > 0 {
            let path = "/tmp/clipkitty_\(deviceKind.filenameStem)_failure_screenshot.png"
            try? XCUIScreen.main.screenshot().pngRepresentation.write(
                to: URL(fileURLWithPath: path)
            )
        }
        try super.tearDownWithError()
    }

    func testTakeMarketingScreenshots() throws {
        // App controls use stable accessibility identifiers. System search
        // controls on the Duo rail use their native roles and localized labels.
        // Missing controls must fail rather than produce duplicate scenes.

        // Screenshot 1: History feed (default state)
        let feedScreenshot = captureScreen()
        saveScreenshot(feedScreenshot, index: 1, name: "history")

        // Screenshot 2: Fuzzy search in action. "dockr push" has a
        // deliberate typo ("dockr"→docker) to showcase the typo-tolerant
        // fuzzy matcher. Both "docker" and "push" appear verbatim in every
        // locale's synthetic DB (technical tokens in untranslated shell
        // commands), so the same query works across all locales.
        let searchButton: XCUIElement
        switch deviceKind {
        case .iPhoneDuo:
            searchButton = try app.buttons[XCTUnwrap(Self.nativeSearchLabels[locale]).search]
        case .iPhone, .iPad:
            searchButton = app.buttons["bottomBar.searchButton"]
        }
        XCTAssertTrue(searchButton.waitForExistence(timeout: 5),
                      "Search button not found for locale \(locale!)")
        searchButton.tap()
        sleep(1)

        // Dismiss the iOS keyboard "slide to type" tutorial if it appears
        dismissKeyboardTutorial()

        // The same 5s budget the other waits get. This one is reached right
        // after dismissKeyboardTutorial() has already spent up to 2s waiting
        // on a button that usually never appears, so a shorter timeout here
        // was the first to expire on a loaded CI runner and failed the whole
        // capture for one locale.
        let searchField: XCUIElement
        switch deviceKind {
        case .iPhoneDuo: searchField = app.searchFields.firstMatch
        case .iPhone, .iPad: searchField = app.textFields["bottomBar.searchField"]
        }
        XCTAssertTrue(searchField.waitForExistence(timeout: 5),
                      "Search field not found for locale \(locale!)")
        typeSearchQuery("dockr push", into: searchField)
        sleep(2)
        waitForFeedSettled(context: "search results")

        let searchScreenshot = captureScreen()
        saveScreenshot(searchScreenshot, index: 2, name: "search")

        // Dismiss search
        let closeButton: XCUIElement
        switch deviceKind {
        case .iPhoneDuo:
            // The rail uses a localized close symbol rather than Cancel.
            // Its English accessibility label starts with a lowercase letter.
            let label = try XCTUnwrap(Self.nativeSearchLabels[locale]).close
            closeButton = app.buttons.matching(NSPredicate(format: "label ==[c] %@", label)).firstMatch
        case .iPhone, .iPad:
            closeButton = app.buttons["bottomBar.closeSearchButton"]
        }
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5),
                      "Close search button not found for locale \(locale!)")
        closeButton.tap()
        sleep(1)

        // Screenshot 3: Filtered view (by Images)
        let filterPill = app.buttons["bottomBar.filterPill"]
        XCTAssertTrue(filterPill.waitForExistence(timeout: 5),
                      "bottomBar.filterPill not found for locale \(locale!)")
        filterPill.tap()
        sleep(1)

        let imagesFilter = app.buttons["bottomBar.filterOption.images"]
        XCTAssertTrue(imagesFilter.waitForExistence(timeout: 5),
                      "bottomBar.filterOption.images not found for locale \(locale!)")
        imagesFilter.tap()
        // Filtering down to images surfaces a screenful of image cards
        // simultaneously; each one async-loads and decodes its
        // full-resolution data, and on a loaded few-core CI runner that
        // burst takes well over 15s end to end. The settled signal is keyed
        // to the images filter, so it can't fire off the still-displayed
        // pre-filter rows; it flips only once the filtered content is loaded
        // and its image burst has finished — this capture is the one that
        // ships to the App Store, and it must never ship a placeholder card.
        sleep(2)
        waitForFeedSettled(filterKind: "images", context: "images filter")

        let filterScreenshot = captureScreen()
        saveScreenshot(filterScreenshot, index: 3, name: "filter")

        // Screenshot 4: the share sheet over the feed.
        captureShareSheetScreenshot()
    }

    // MARK: - Native search labels

    private static let nativeSearchLabels: [String: (search: String, close: String)] = [
        "en": ("Search", "Close"),
        "de": ("Suchen", "Schließen"),
        "es": ("Buscar", "Cerrar"),
        "fr": ("Rechercher", "Fermer"),
        "ja": ("検索", "閉じる"),
        "ko": ("검색", "닫기"),
        "pt-BR": ("Buscar", "Fechar"),
        "ru": ("Поиск", "Закрыть"),
        "zh-Hans": ("搜索", "关闭"),
        "zh-Hant": ("搜尋", "關閉"),
    ]

    // MARK: - Share sheet screenshot

    private func captureShareSheetScreenshot() {
        switch deviceKind {
        case .iPhoneDuo:
            captureShareSheetFromSelection()
        case .iPhone, .iPad:
            captureShareSheetFromContextMenu()
        }
    }

    private static let shareMenuTitles: [String: String] = [
        "en": "Share",
        "de": "Teilen",
        "es": "Compartir",
        "fr": "Partager",
        "ja": "共有",
        "ko": "공유",
        "pt-BR": "Compartilhar",
        "ru": "Поделиться",
        "zh-Hans": "共享",
        "zh-Hant": "分享",
    ]

    /// Long-presses the first clip card and opens the system share sheet via
    /// the context menu's Share action.
    private func captureShareSheetFromContextMenu() {
        // Back to the unfiltered feed so the sheet presents over the hero
        // content — the images filter from the previous capture is still
        // active at this point.
        let filterPill = app.buttons["bottomBar.filterPill"]
        XCTAssertTrue(filterPill.waitForExistence(timeout: 5),
                      "bottomBar.filterPill not found for locale \(locale!)")
        filterPill.tap()
        sleep(1)
        let allFilter = app.buttons["bottomBar.filterOption.all"]
        XCTAssertTrue(allFilter.waitForExistence(timeout: 5),
                      "bottomBar.filterOption.all not found for locale \(locale!)")
        allFilter.tap()
        sleep(1)
        waitForFeedSettled(context: "share screenshot prep")

        guard let shareTitle = Self.shareMenuTitles[locale] else {
            XCTFail("no share menu title mapped for locale \(locale!)")
            return
        }

        let maxAttempts = 2
        var foundCard = false
        var shareItem: XCUIElement?

        for attempt in 1 ... maxAttempts {
            // Resolve the card again on every attempt because dismissing a
            // context-menu lift can invalidate the previous element snapshot.
            let firstCard = app.scrollViews.firstMatch.buttons.firstMatch
            if firstCard.waitForExistence(timeout: 5) {
                foundCard = true
                XCTAssertTrue(
                    firstCard.isHittable,
                    "first card has a visible accessibility frame but no hit target (locale \(locale!))"
                )
                firstCard.press(forDuration: 1.2)

                // Let the system finish presenting the context menu before
                // asking XCTest for a fresh accessibility hierarchy.
                sleep(1)

                // On newer iOS simulators, context-menu actions can be exposed
                // as a menu item rather than a button. The localized action
                // label is the stable contract across those accessibility roles.
                let candidate = app.descendants(matching: .any).matching(
                    NSPredicate(format: "label == %@", shareTitle)
                ).firstMatch
                if candidate.waitForExistence(timeout: 5) {
                    shareItem = candidate
                    break
                }
            }

            if attempt < maxAttempts {
                // Dismiss either a half-presented menu or a drag lift before
                // retrying. The top-left status-bar area is outside the card
                // and menu, and tapping it is harmless while the feed is at top.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.02)).tap()
                Thread.sleep(forTimeInterval: 0.5)
            }
        }

        guard foundCard else {
            XCTFail("no card found for share screenshot (locale \(locale!))")
            return
        }
        guard let shareItem else {
            XCTFail("context menu Share item ('\(shareTitle)') not found for locale \(locale!)")
            return
        }
        shareItem.tap()

        // Give the activity sheet time to lay out its app row and previews.
        sleep(4)

        saveScreenshot(captureScreen(), index: 4, name: "share")
    }

    /// Uses the feed's selection toolbar to open the real system share sheet.
    /// The toolbar has stable identifiers across locales and avoids the
    /// simulator's context-menu lift and accessibility animation timeouts.
    private func captureShareSheetFromSelection() {
        let filterPill = app.buttons["bottomBar.filterPill"]
        XCTAssertTrue(filterPill.waitForExistence(timeout: 5),
                      "bottomBar.filterPill not found for locale \(locale!)")
        filterPill.tap()
        let allFilter = app.buttons["bottomBar.filterOption.all"]
        XCTAssertTrue(allFilter.waitForExistence(timeout: 5),
                      "bottomBar.filterOption.all not found for locale \(locale!)")
        allFilter.tap()
        waitForFeedSettled(context: "share screenshot prep")

        let overflow = app.buttons["home.overflowMenuButton"]
        XCTAssertTrue(overflow.waitForExistence(timeout: 5))
        overflow.tap()
        let select = app.buttons["home.selectMenuItem"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()

        let firstCard = app.scrollViews.firstMatch.buttons.firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 5),
                      "no card found for share screenshot (locale \(locale!))")
        firstCard.tap()
        let share = app.buttons["selection.shareButton"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        XCTAssertTrue(share.isEnabled)
        share.tap()

        let sheet = app.descendants(matching: .any)["shareSheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 15),
                      "system share sheet did not appear (locale \(locale!))")
        // The presentation completion publishes the identifier; let its final
        // rendered frame reach the screenshot buffer before capturing it.
        sleep(1)
        saveScreenshot(captureScreen(), index: 4, name: "share")
    }

    // MARK: - Verified typing

    /// Types `text` into `field` and confirms every character actually
    /// arrived, retyping until it does.
    ///
    /// On the first keyboard bring-up after a simulator boot, `typeText`
    /// can post its key events while the text-input session is still
    /// connecting; the events are dropped silently and the call still
    /// returns as a success. The en iPad capture of run 28816034636
    /// shipped to the App Store with an empty search field exactly this
    /// way — first locale of the job, cold simulator, test green. Only
    /// reading the field's value back distinguishes that run from a real
    /// one: a retype lands once the input session is up, and a loud
    /// failure here beats a query-less marketing screenshot.
    private func typeSearchQuery(_ text: String, into field: XCUIElement) {
        // While the field is empty its accessibility value reads as the
        // localized placeholder; snapshot it so residue detection below
        // can tell "empty" from "partially typed".
        let placeholder = field.value as? String
        let maxAttempts = 5
        for attempt in 1 ... maxAttempts {
            // Clear residue from a prior partial attempt (including
            // keystrokes that arrived after the last read-back) so a
            // retype can't double up the query. The caret sits after the
            // residue, so deletes remove all of it.
            if let residue = field.value as? String,
               residue != placeholder, !residue.isEmpty
            {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                      count: residue.count))
            }
            field.typeText(text)
            // Give a still-connecting input session a beat to deliver the
            // keystrokes before reading the value back.
            sleep(1)
            if (field.value as? String) == text { return }
            print("typeSearchQuery: attempt \(attempt)/\(maxAttempts) dropped keystrokes; retrying")
        }
        XCTFail("Search query '\(text)' never landed after \(maxAttempts) attempts " +
            "(locale \(locale!)) — capturing would ship an empty search field")
    }

    // MARK: - Image-load settling

    /// Blocks until the app reports the feed fully settled for the given
    /// filter, via the feed's load-state accessibility identifier
    /// (`feed.<filterKind>.settled`, the iOS counterpart of the Mac's
    /// `ResultsState_<kind>_loaded` signal): the filter's query has loaded
    /// and every in-flight card image fetch/decode has finished. Deterministic
    /// on purpose — fixed sleeps kept shipping mid-decode captures on loaded
    /// CI runners.
    ///
    /// The timeout is a failure backstop, not pacing — the wait returns as
    /// soon as the app settles. 240s accommodates a cold CI runner decoding a
    /// screenful of full-resolution marketing images behind a utility-QoS
    /// queue (each wedge-netted at 60s in `DecodedImageView.decodeOffPool`).
    private func waitForFeedSettled(
        filterKind: String = "all",
        timeout: TimeInterval = 240,
        context: String
    ) {
        let settled = app.descendants(matching: .any)["feed.\(filterKind).settled"]
        let deadline = Date().addingTimeInterval(timeout)
        var isStable = false
        while !isStable, Date() < deadline {
            guard settled.waitForExistence(timeout: max(1, deadline.timeIntervalSinceNow)) else {
                break
            }
            // One extra beat so the final decoded frame reaches the display
            // buffer that `XCUIScreen.main.screenshot()` grabs — and to reject
            // a transient settle: freshly landed rows can read settled for a
            // frame before their placeholder cards flip the feed back to
            // loading (the App Store iPhone Images screenshot shipped a
            // placeholder card through exactly that frame). Only capture once
            // the settle survives the beat.
            sleep(1)
            isStable = settled.exists
        }
        if !isStable {
            let prefix = "/tmp/clipkitty_\(deviceKind.filenameStem)_feed_failure"
            try? app.debugDescription.write(
                toFile: prefix + "_screenshot_test.log", atomically: true, encoding: .utf8
            )
            try? XCUIScreen.main.screenshot().pngRepresentation.write(
                to: URL(fileURLWithPath: prefix + "_screenshot.png")
            )
        }
        XCTAssertTrue(
            isStable,
            "Feed did not settle within \(Int(timeout))s (\(context), locale \(locale!)) — capturing would ship placeholder cards"
        )
    }

    // MARK: - Screen capture

    /// Captures the whole display via `XCUIScreen`, deliberately *not*
    /// `XCUIApplication.screenshot()`.
    ///
    /// `app.screenshot()` resolves the app through a UI query that first waits
    /// for the app to report idle. The packed iPad feed does a burst of layout
    /// and async image-decode work as cards appear, and on a loaded CI runner
    /// that burst can outlast the automation idle timeout — the query then
    /// fails with "Timed out while evaluating UI query" and no screenshot is
    /// produced at all. `XCUIScreen.main.screenshot()` grabs the display buffer
    /// directly with no idle query, so once we have given the feed our own
    /// settle time the capture always succeeds. Callers still drive the UI
    /// through `app`'s element queries (with their own short waits); only the
    /// final pixel grab bypasses the app-idle wait.
    private func captureScreen() -> XCUIScreenshot {
        XCUIScreen.main.screenshot()
    }

    // MARK: - Database Setup

    /// Copies the locale-appropriate SyntheticData.sqlite to a temp path and returns
    /// the path for the app to use via `CLIPKITTY_SCREENSHOT_DB` environment variable.
    private func setupTestDatabase() throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // iOSUITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // project root

        let databaseFilename = readTempConfig(Self.dbConfigFile, defaultValue: "SyntheticData.sqlite") ?? "SyntheticData.sqlite"
        let sqliteSourceURL = projectRoot.appendingPathComponent("distribution/\(databaseFilename)")

        guard FileManager.default.fileExists(atPath: sqliteSourceURL.path) else {
            XCTFail("\(databaseFilename) not found at: \(sqliteSourceURL.path). Run 'git lfs pull' and ensure distribution/SyntheticData*.sqlite is checked out.")
            return ""
        }

        // Guard against Git LFS pointer files
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: sqliteSourceURL.path)[.size] as? Int) ?? 0
        if fileSize < 1024 {
            let headerData = FileManager.default.contents(atPath: sqliteSourceURL.path).flatMap { data in
                String(data: data.prefix(64), encoding: .utf8)
            }
            if headerData?.contains("git-lfs.github.com") == true {
                XCTFail("Git LFS pointer not resolved for \(databaseFilename). Run 'git lfs pull' first.")
                return ""
            }
            XCTFail("\(databaseFilename) is too small (\(fileSize) bytes) — likely corrupt or an LFS pointer.")
            return ""
        }

        // Copy to a temp location the app can read
        let targetPath = "/tmp/clipkitty_ios_screenshot.sqlite"
        try? FileManager.default.removeItem(atPath: targetPath)
        // Also remove WAL/SHM companions
        try? FileManager.default.removeItem(atPath: targetPath + "-wal")
        try? FileManager.default.removeItem(atPath: targetPath + "-shm")
        // Blow away any Tantivy index dirs next to the target — otherwise
        // a prior locale's index persists across runs and we end up
        // searching stale content (the bootstrap check returns Ready
        // when the index is populated, even if its docs don't match the
        // sqlite file we just copied in).
        let tmpDir = URL(fileURLWithPath: "/tmp")
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: tmpDir.path) {
            for name in contents where name.hasPrefix("tantivy_index_") {
                try? FileManager.default.removeItem(atPath: tmpDir.appendingPathComponent(name).path)
            }
        }
        try FileManager.default.copyItem(atPath: sqliteSourceURL.path, toPath: targetPath)

        let copiedSize = (try? FileManager.default.attributesOfItem(atPath: targetPath)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(copiedSize, 1024,
                             "Copied database is too small (\(copiedSize) bytes). Target: \(targetPath)")

        return targetPath
    }

    // MARK: - Keyboard Tutorial

    /// Dismiss the iOS keyboard's "slide to type" onboarding overlay if it appears.
    /// The overlay has a "Continue" button that must be tapped to reveal the normal keyboard.
    private func dismissKeyboardTutorial() {
        let continueButton = app.buttons["Continue"]
        if continueButton.waitForExistence(timeout: 2) {
            continueButton.tap()
            sleep(1)
        }
    }

    // MARK: - Helpers

    private func readTempConfig(_ filename: String, defaultValue: String? = nil) -> String? {
        if let content = try? String(contentsOfFile: "/tmp/\(filename)", encoding: .utf8) {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return defaultValue
    }

    private func saveScreenshot(_ screenshot: XCUIScreenshot, index: Int, name: String) {
        if case .iPhoneDuo = deviceKind {
            let image = screenshot.image
            XCTAssertEqual(image.size.width * image.scale, 1398,
                           "Duo marketing screenshots must capture the outer display")
            XCTAssertEqual(image.size.height * image.scale, 2034,
                           "Duo marketing screenshots must capture the outer display in portrait")
        }
        let localePrefix = locale == "en" ? "" : "\(locale!)_"
        let filename = "clipkitty_\(deviceKind.filenameStem)_\(localePrefix)marketing_\(index)_\(name).png"
        let path = "/tmp/\(filename)"

        let data = screenshot.pngRepresentation
        FileManager.default.createFile(atPath: path, contents: data)
        print("Saved screenshot: \(path)")

        // Also add as XCTest attachment for artifact collection
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "marketing_\(index)_\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
