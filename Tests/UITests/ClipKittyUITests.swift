import XCTest

final class ClipKittyUITests: XCTestCase {
    var app: XCUIApplication!

    /// Locale for localized screenshot capture, read from SCREENSHOT_LOCALE env var.
    /// When set (e.g. "ja", "de"), the app launches in that locale and demo content is patched.
    private var screenshotLocale: String? {
        let locale = ProcessInfo.processInfo.environment["SCREENSHOT_LOCALE"]
        if let locale, !locale.isEmpty, locale != "en" {
            return locale
        }
        return nil
    }

    // MARK: - Localized Demo Content

    /// Localized versions of the ClipKitty marketing bullet points shown in screenshot 1.
    /// These replace the English text in SyntheticData.sqlite for localized screenshots.
    private static let localizedBulletPoints: [String: String] = [
        "es": """
            ClipKitty
            • Cópialo una vez, encuéntralo siempre
            • La búsqueda inteligente perdona tus errores
            • Ve bloques de código completos antes de pegar
            • ⌥Espacio para invocar, teclado primero
            • Tus datos nunca salen de tu Mac
            """,
        "zh-Hans": """
            ClipKitty
            • 复制一次，永久查找
            • 智能搜索容忍拼写错误
            • 粘贴前查看完整代码块
            • ⌥空格唤出，键盘优先
            • 数据永不离开你的 Mac
            """,
        "zh-Hant": """
            ClipKitty
            • 複製一次，永遠找得到
            • 智慧搜尋容忍拼字錯誤
            • 貼上前檢視完整程式碼區塊
            • ⌥Space 喚出，鍵盤優先
            • 資料永遠不會離開你的 Mac
            """,
        "ja": """
            ClipKitty
            • 一度コピーすれば、いつでも見つかる
            • スマート検索でタイプミスも許容
            • ペースト前にコードブロック全体を確認
            • ⌥Spaceで呼び出し、キーボード操作
            • データがMacの外に出ることはありません
            """,
        "ko": """
            ClipKitty
            • 한 번 복사하면 영원히 검색 가능
            • 스마트 검색으로 오타도 문제없음
            • 붙여넣기 전에 전체 코드 블록 확인
            • ⌥Space로 호출, 키보드 중심
            • 데이터가 Mac 밖으로 나가지 않음
            """,
        "fr": """
            ClipKitty
            • Copiez une fois, retrouvez toujours
            • La recherche intelligente pardonne les fautes
            • Visualisez les blocs de code avant de coller
            • ⌥Espace pour invoquer, clavier d'abord
            • Vos données ne quittent jamais votre Mac
            """,
        "de": """
            ClipKitty
            • Einmal kopieren, für immer finden
            • Intelligente Suche verzeiht Tippfehler
            • Code-Blöcke vor dem Einfügen ansehen
            • ⌥Leertaste zum Aufrufen, Tastatur zuerst
            • Deine Daten verlassen nie deinen Mac
            """,
        "pt-BR": """
            ClipKitty
            • Copie uma vez, encontre para sempre
            • A busca inteligente perdoa erros de digitação
            • Veja blocos de código completos antes de colar
            • ⌥Espaço para chamar, teclado primeiro
            • Seus dados nunca saem do seu Mac
            """,
        "ru": """
            ClipKitty
            • Скопируйте один раз — находите всегда
            • Умный поиск прощает опечатки
            • Просматривайте блоки кода перед вставкой
            • ⌥Пробел для вызова, клавиатура в приоритете
            • Ваши данные никогда не покидают Mac
            """,
    ]

    /// Read the bundle identifier from the app's Info.plist
    private func getBundleIdentifier(for appURL: URL) -> String {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        if let plist = NSDictionary(contentsOf: plistURL),
           let bundleId = plist["CFBundleIdentifier"] as? String {
            return bundleId
        }
        return "com.eviljuliette.clipkitty"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false

        let appURL = try locateAppBundle()
        app = XCUIApplication(url: appURL)

        let appSupportDir = getAppSupportDirectory(for: appURL)
        try setupTestDatabase(in: appSupportDir)

        // Patch localized demo content if a screenshot locale is set
        if let locale = screenshotLocale {
            patchLocalizedDemoContent(in: appSupportDir, locale: locale)
        }

        app.launchArguments = ["--use-simulated-db"]

        // Set app locale for localized screenshots
        if let locale = screenshotLocale {
            app.launchArguments += ["-AppleLanguages", "(\(locale))"]
            app.launchArguments += ["-AppleLocale", locale]
        }

        app.launch()

        // Wait for the search field — it's always present regardless of how
        // the accessibility system classifies the NSPanel (window vs dialog).
        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(
            searchField.waitForExistence(timeout: 15),
            "App UI did not appear. Hierarchy: \(app.debugDescription)"
        )
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: - Setup Helpers

    private func locateAppBundle() throws -> URL {
        if let envPath = ProcessInfo.processInfo.environment["CLIPKITTY_APP_PATH"] {
            return URL(fileURLWithPath: envPath)
        }

        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appURL = projectRoot.appendingPathComponent("ClipKitty.app")

        if FileManager.default.fileExists(atPath: appURL.path) {
            return appURL
        }

        // Fallback: traverse up from bundle
        let testBundle = Bundle(for: type(of: self))
        var url = testBundle.bundleURL
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("ClipKitty.app").path) && url.path != "/" {
            url = url.deletingLastPathComponent()
        }
        return url.appendingPathComponent("ClipKitty.app")
    }

    private func getAppSupportDirectory(for appURL: URL) -> URL {
        let bundleId = getBundleIdentifier(for: appURL)
        let userHome = URL(fileURLWithPath: "/Users/\(NSUserName())")
        return userHome.appendingPathComponent("Library/Containers/\(bundleId)/Data/Library/Application Support/ClipKitty")
    }

    private func setupTestDatabase(in appSupportDir: URL) throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sqliteSourceURL = projectRoot.appendingPathComponent("distribution/SyntheticData.sqlite")
        let targetURL = appSupportDir.appendingPathComponent("clipboard-screenshot.sqlite")
        let indexDirURL = appSupportDir.appendingPathComponent("tantivy_index_v3")

        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

        // Kill existing instances and clean up old data
        let killTask = Process()
        killTask.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killTask.arguments = ["-9", "ClipKitty"]
        try? killTask.run()
        killTask.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.2)

        try? FileManager.default.removeItem(at: targetURL)
        try? FileManager.default.removeItem(at: indexDirURL)
        try? FileManager.default.removeItem(at: targetURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: targetURL.appendingPathExtension("shm"))

        guard FileManager.default.fileExists(atPath: sqliteSourceURL.path) else {
            XCTFail("SyntheticData.sqlite not found at: \(sqliteSourceURL.path)")
            return
        }
        try FileManager.default.copyItem(at: sqliteSourceURL, to: targetURL)
    }

    /// Patches the ClipKitty bullet points in the copied SQLite database with localized text.
    /// This makes the most visible demo item (top of history list) appear in the target language.
    private func patchLocalizedDemoContent(in appSupportDir: URL, locale: String) {
        guard let localizedText = Self.localizedBulletPoints[locale] else { return }

        let dbPath = appSupportDir.appendingPathComponent("clipboard-screenshot.sqlite").path
        let escaped = localizedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "'", with: "''")

        let sql = "UPDATE text_items SET value = '\(escaped)' WHERE value LIKE 'ClipKitty%Copy it once%';"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, sql]
        try? process.run()
        process.waitUntilExit()
    }

    /// Helper to get the currently selected index by finding the button with isSelected trait
    private func getSelectedIndex() -> Int? {
        // Items are Button elements inside Cell elements inside the Outline
        // Find which button is selected
        let buttons = app.outlines.firstMatch.buttons.allElementsBoundByIndex
        for (index, button) in buttons.enumerated() {
            if button.isSelected {
                return index
            }
        }
        return nil
    }

    /// Helper to wait for selected index to equal expected value
    private func waitForSelectedIndex(_ expected: Int, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if getSelectedIndex() == expected {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return getSelectedIndex() == expected
    }

    // MARK: - Tests

    /// Regression test: verify the synthetic database was correctly seeded.
    /// If this fails, the DB is likely being placed in the wrong sandbox container path.
    func testDatabaseNotEmpty() throws {
        let items = app.outlines.firstMatch.buttons.allElementsBoundByIndex
        XCTAssertGreaterThan(items.count, 0, "Database should contain items — empty DB indicates a seeding/path regression")
    }

    /// Tests that first item is selected on initial open.
    /// There should always be an item selected when items exist.
    func testFirstItemSelectedOnOpen() throws {
        // First item should be selected immediately after open
        XCTAssertTrue(waitForSelectedIndex(0, timeout: 3), "First item should be selected on open")

        // Verify we actually have items
        let buttons = app.outlines.firstMatch.buttons.allElementsBoundByIndex
        XCTAssertGreaterThan(buttons.count, 0, "Should have items in the list")
    }


    /// Tests that Cmd+number shortcuts select and paste the corresponding history item.
    /// Cmd+2 should target the second item (index 1).
    func testCommandNumberShortcutSelectsSecondItem() throws {
        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Ensure keyboard focus and initial selection are stable.
        searchField.click()
        XCTAssertTrue(waitForSelectedIndex(0, timeout: 2), "Initial selection should be first item")

        app.typeKey("2", modifierFlags: .command)

        XCTAssertTrue(
            waitForSelectedIndex(1, timeout: 2),
            "Cmd+2 should select the second item before paste"
        )
    }

    /// Tests that selection resets to first when the selected item's position changes in the list.
    /// Selection should only reset when items are reordered, not on every search text change.
    func testSelectionResetsWhenItemPositionChanges() throws {
        let searchField = app.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Initial state: first item should be selected
        XCTAssertTrue(waitForSelectedIndex(0), "Initial selection should be index 0")

        // Move selection down to item 3
        searchField.click()
        for _ in 0..<3 {
            searchField.typeText(XCUIKeyboardKey.downArrow.rawValue)
        }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(getSelectedIndex(), 3, "Selection should have moved to index 3")

        // Type a search query that filters results - this changes item positions
        // so selection should reset to first
        searchField.typeText("the")
        Thread.sleep(forTimeInterval: 0.3)

        // Selection should reset because the item order changed
        XCTAssertTrue(waitForSelectedIndex(0, timeout: 2), "Selection should reset when item positions change")
    }



    /// Tests that the panel hides when focus moves to another application.
    /// This is Spotlight-like behavior - the panel should auto-dismiss on focus loss.
    func testPanelHidesOnFocusLoss() throws {
        let window = app.dialogs.firstMatch
        XCTAssertTrue(window.exists, "Window should be visible initially")

        // Click somewhere outside the app to lose focus
        // We'll use Finder as the other app
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()

        // Wait for the window to disappear
        let disappeared = window.waitForNonExistence(timeout: 3)
        XCTAssertTrue(disappeared, "Window should hide when focus moves to another app")
    }

    /// Tests that the panel does NOT auto-show when the app is activated/focused.
    /// The panel should only appear via hotkey or menu - not automatically on app focus.
    /// This ensures settings and other interactions don't get overlaid by the panel.
    func testPanelDoesNotAutoShowOnAppFocus() throws {
        let panel = app.dialogs.firstMatch
        XCTAssertTrue(panel.exists, "Panel should be visible initially")

        // First, hide the panel by activating another app
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3), "Panel should hide when focus lost")

        // Re-activate the app - panel should NOT auto-show
        app.activate()
        Thread.sleep(forTimeInterval: 0.5)

        // Panel should still be hidden - it should only show via hotkey/menu
        XCTAssertFalse(panel.exists, "Panel should NOT auto-show when app is activated")

        // Now open settings - it should work without panel overlay
        app.typeKey(",", modifierFlags: .command)
        let settingsWindow = app.windows["ClipKitty Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3), "Settings window should appear")
        XCTAssertTrue(settingsWindow.isHittable, "Settings window should be interactable")

        // Panel should still not be visible
        XCTAssertFalse(panel.exists, "Panel should NOT appear when settings is opened")
    }

    /// Tests that clicking on the preview text area allows text selection
    /// instead of dragging the window.
    func testPreviewTextIsSelectable() throws {
        let window = app.dialogs.firstMatch
        XCTAssertTrue(window.exists, "Window should be visible")

        // Record initial window position
        let initialFrame = window.frame

        // Find the text view in the preview pane (it's a scroll view with text)
        let scrollViews = window.scrollViews
        XCTAssertGreaterThan(scrollViews.count, 0, "Should have scroll views")

        // The preview pane's scroll view - try to find the text area
        // Click and drag on the preview text area
        let previewArea = scrollViews.element(boundBy: scrollViews.count - 1)
        XCTAssertTrue(previewArea.exists, "Preview scroll view should exist")

        // Perform a click-drag that would normally move the window
        let startPoint = previewArea.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3))
        let endPoint = previewArea.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.3))
        startPoint.click(forDuration: 0.1, thenDragTo: endPoint)

        // Wait a moment for any potential window movement
        Thread.sleep(forTimeInterval: 0.3)

        // Window should NOT have moved - the drag should select text, not move window
        let finalFrame = window.frame
        XCTAssertEqual(initialFrame.origin.x, finalFrame.origin.x, accuracy: 5,
                       "Window X position should not change when clicking preview text")
        XCTAssertEqual(initialFrame.origin.y, finalFrame.origin.y, accuracy: 5,
                       "Window Y position should not change when clicking preview text")
    }

    /// Tests that the content-type filter dropdown is visible and functional.
    /// The dropdown capsule must be hittable (rendered with nonzero frame and sufficient contrast),
    /// open a popover with filter options, and allow selecting a filter.
    func testFilterDropdownVisible() throws {
        // 1. Find the filter dropdown button by accessibility identifier
        let filterButton = app.buttons["FilterDropdown"]
        XCTAssertTrue(filterButton.waitForExistence(timeout: 5), "Filter dropdown button should exist")
        XCTAssertTrue(filterButton.isHittable, "Filter dropdown button should be hittable (visible with nonzero frame)")

        // Screenshot: dropdown closed
        saveScreenshot(name: "filter_closed")

        // 2. Click to open the popover
        filterButton.click()
        Thread.sleep(forTimeInterval: 0.5)

        // 3. Verify popover content appears with filter options
        // FilterOptionRow uses Button, so options appear as buttons in the accessibility tree
        let linksOption = app.buttons["Links"]
        XCTAssertTrue(linksOption.waitForExistence(timeout: 3), "Popover should show 'Links' option")

        // Screenshot: dropdown open
        saveScreenshot(name: "filter_open")

        // 4. Select "Links Only" and verify the button label changes
        linksOption.click()
        Thread.sleep(forTimeInterval: 0.5)

        // After selecting, the button label should reflect the new filter
        let updatedButton = app.buttons["FilterDropdown"]
        XCTAssertTrue(updatedButton.waitForExistence(timeout: 3), "Filter button should still exist after selection")
        XCTAssertTrue(updatedButton.isHittable, "Filter button should remain hittable after selection")

        // The button label should now say "Links" instead of "All Types"
        XCTAssertTrue(updatedButton.label.contains("Links"), "Filter button should show 'Links' after selecting Links Only, got: '\(updatedButton.label)'")
    }

    // MARK: - Actions Menu

    /// Tests that the actions button is visible in the metadata footer.
    func testActionsButtonVisible() throws {
        let actionsButton = app.buttons["ActionsButton"]
        XCTAssertTrue(actionsButton.waitForExistence(timeout: 5), "Actions button should exist in footer")
        XCTAssertTrue(actionsButton.isHittable, "Actions button should be hittable")
    }

    /// Tests that clicking the actions button opens a popover with action options.
    func testActionsPopoverOpensOnClick() throws {
        let actionsButton = app.buttons["ActionsButton"]
        XCTAssertTrue(actionsButton.waitForExistence(timeout: 5), "Actions button should exist")

        actionsButton.click()
        Thread.sleep(forTimeInterval: 0.5)

        // Should show at least Copy/Paste and Delete options
        let deleteAction = app.buttons["Action_Delete"]
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 3), "Delete action should appear in popover")

        // Default action should be Copy (no accessibility permission in test env)
        let copyAction = app.buttons["Action_Copy"]
        XCTAssertTrue(copyAction.waitForExistence(timeout: 3), "Copy action should appear in popover")
    }

    /// Tests that Option+Return opens the actions popover.
    func testOptionReturnOpensActionsPopover() throws {
        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Option+Return should open the actions menu
        searchField.typeKey(.return, modifierFlags: .option)
        Thread.sleep(forTimeInterval: 0.5)

        let deleteAction = app.buttons["Action_Delete"]
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 3), "Actions popover should open with Option+Return")
    }

    /// Tests that Escape closes the actions popover.
    func testEscapeClosesActionsPopover() throws {
        let actionsButton = app.buttons["ActionsButton"]
        XCTAssertTrue(actionsButton.waitForExistence(timeout: 5))

        actionsButton.click()
        Thread.sleep(forTimeInterval: 0.5)

        let deleteAction = app.buttons["Action_Delete"]
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 3), "Popover should be open")

        // Press Escape to close
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertFalse(deleteAction.exists, "Popover should close after Escape")
    }

    /// Tests that the Delete action in the popover shows inline confirmation.
    func testDeleteActionShowsConfirmation() throws {
        let actionsButton = app.buttons["ActionsButton"]
        XCTAssertTrue(actionsButton.waitForExistence(timeout: 5))

        actionsButton.click()
        Thread.sleep(forTimeInterval: 0.5)

        let deleteAction = app.buttons["Action_Delete"]
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 3))

        deleteAction.click()
        Thread.sleep(forTimeInterval: 0.5)

        // Inline confirmation should appear within the popover (not a system alert)
        let confirmDelete = app.buttons["Action_Delete"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 3), "Inline delete confirmation should appear")
        let cancelButton = app.buttons["Action_Cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 3), "Cancel button should appear in confirmation")
    }

    /// Tests the full delete-via-keyboard flow: open actions, navigate to delete, confirm inline.
    func testDeleteItemViaKeyboard() throws {
        let searchField = app.textFields["SearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Record initial item count
        let initialCount = app.outlines.firstMatch.buttons.allElementsBoundByIndex.count
        XCTAssertGreaterThan(initialCount, 0, "Should have items to delete")

        // Press Option+Return to open actions popover
        searchField.typeKey(.return, modifierFlags: .option)
        Thread.sleep(forTimeInterval: 0.5)

        let deleteAction = app.buttons["Action_Delete"]
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 3), "Actions popover should open")

        // Navigate to Delete (it's the first item) with up arrow
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.upArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.2)

        // Press Return to select Delete
        app.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        // Inline confirmation should appear
        let confirmDelete = app.buttons["Action_Delete"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 3), "Inline delete confirmation should appear")

        // Press Return to confirm deletion (Delete button should be highlighted)
        app.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        // Verify: item count decreased
        let finalCount = app.outlines.firstMatch.buttons.allElementsBoundByIndex.count
        XCTAssertEqual(finalCount, initialCount - 1, "Item count should decrease by 1 after deletion")

        // Verify: window is still visible (not hidden)
        let window = app.dialogs.firstMatch
        XCTAssertTrue(window.exists, "Window should still be visible after deletion")
    }

    // MARK: - Marketing Assets

    /// Captures a marketing-ready screenshot: crops a 16:10 rectangle centered
    /// on the app window from the full-screen capture, then upscales to 2880×1800.
    /// The neutral desktop background (set by `prepare-screenshot-environment.sh`)
    /// fills the padding area around the window.
    private func saveScreenshot(name: String) {
        let window = app.dialogs.firstMatch
        if !window.exists {
            return
        }

        // Allow items to fully load before capturing
        Thread.sleep(forTimeInterval: 1.0)

        let frame = window.frame
        let screenShot = XCUIScreen.main.screenshot()
        let image = screenShot.image
        let scaleFactor = NSScreen.main?.backingScaleFactor ?? 1.0

        // Start with window frame + minimum padding (40pt on all sides)
        let minPadding: CGFloat = 40
        var cropWidth = frame.width + minPadding * 2
        var cropHeight = frame.height + minPadding * 2

        // Expand the smaller dimension so the crop is exactly 16:10
        let targetRatio: CGFloat = 16.0 / 10.0
        let currentRatio = cropWidth / cropHeight
        if currentRatio < targetRatio {
            // Too tall — widen
            cropWidth = cropHeight * targetRatio
        } else {
            // Too wide — heighten
            cropHeight = cropWidth / targetRatio
        }

        // Center the crop on the window center
        let centerX = frame.midX
        let centerY = frame.midY
        let cropRect = CGRect(
            x: max((centerX - cropWidth / 2) * scaleFactor, 0),
            y: max((centerY - cropHeight / 2) * scaleFactor, 0),
            width: cropWidth * scaleFactor,
            height: cropHeight * scaleFactor
        )

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cropped = cgImage.cropping(to: cropRect) else {
            return
        }

        // Upscale to exactly 2880×1800 pixels using a bitmap context.
        // NSImage.lockFocus() scales with the display's backing factor (2x on Retina),
        // which would produce 5760×3600 on CI's virtual HiDPI display.
        let finalWidth = 2880
        let finalHeight = 1800
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: finalWidth,
            pixelsHigh: finalHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        bitmapRep.size = NSSize(width: finalWidth, height: finalHeight)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
            .draw(in: NSRect(x: 0, y: 0, width: finalWidth, height: finalHeight))
        NSGraphicsContext.restoreGraphicsState()

        if let png = bitmapRep.representation(using: .png, properties: [:]) {
            let localePrefix = screenshotLocale.map { "\($0)_" } ?? ""
            let url = URL(fileURLWithPath: "/tmp/clipkitty_\(localePrefix)\(name).png")
            try? png.write(to: url)

            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// Records a demo of the search functionality for App Store preview video.
    /// Run with: make preview-video
    /// This test types slowly to create a visually appealing demo.
    ///
    /// NOTE: Relies entirely on demo items in SyntheticData.sqlite (generated with --demo flag)
    ///
    /// Script timing (20 seconds total):
    /// Scene 1 (0:00-0:08): Meta pitch - fuzzy search refinement "hello" -> "hello clip"
    ///   - Matches: Hello ClipKitty, hello_world.py, sayHello, Hello and welcome...
    /// Scene 2 (0:08-0:14): Color swatches "#" -> "#f", then image "cat"
    ///   - Matches: #7C3AED, #FF5733, #2DD4BF, #F472B6, Orange tabby cat...
    /// Scene 3 (0:14-0:20): Typo forgiveness "rivresid" finds "Riverside", loop back to empty
    ///   - Matches: Apartment walkthrough...437 Riverside Dr...
    func testRecordSearchDemo() throws {
        let searchField = app.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Save window bounds to temp file for video cropping
        let window = app.dialogs.firstMatch
        if window.exists {
            let frame = window.frame
            // XCUIElement.frame is in points, but screen recording is in pixels
            // Get the scale factor by comparing screenshot pixel size to screen bounds
            let screenshot = XCUIScreen.main.screenshot()
            let screenPixelHeight = screenshot.image.size.height
            let screenPixelWidth = screenshot.image.size.width

            // Get the actual scale factor from NSScreen (works for any display)
            let scaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0

            // Convert frame from points to pixels
            let pixelX = frame.origin.x * scaleFactor
            let pixelY = frame.origin.y * scaleFactor
            let pixelWidth = frame.width * scaleFactor
            let pixelHeight = frame.height * scaleFactor

            // Convert from bottom-left origin (AppKit) to top-left origin (video/ffmpeg)
            // NOTE: XCTest actually uses top-left origin already, so no flip needed
            let topLeftY = pixelY  // Use directly, no conversion

            // Format: x,y,width,height (with some padding for shadow/border)
            let padding: CGFloat = 80  // N points * 2 for scaling
            let boundsString = String(format: "%.0f,%.0f,%.0f,%.0f",
                                       max(0, pixelX - padding),
                                       max(0, topLeftY - padding),
                                       pixelWidth + padding * 2,
                                       pixelHeight + padding * 2)
            try? boundsString.write(toFile: "/tmp/clipkitty_window_bounds.txt",
                                    atomically: true, encoding: .utf8)
        }

        // Signal that the demo is ready to start (shell script will start recording)
        try? "start".write(toFile: "/tmp/clipkitty_demo_start.txt", atomically: true, encoding: .utf8)

        // Wait for recording to start (shell script signals when screencapture is running)
        let recordingStartedPath = "/tmp/clipkitty_recording_started.txt"
        var waitCount = 0
        while !FileManager.default.fileExists(atPath: recordingStartedPath) && waitCount < 20 {
            Thread.sleep(forTimeInterval: 0.5)
            waitCount += 1
        }
        try? FileManager.default.removeItem(atPath: recordingStartedPath)

        // Helper to type with natural delays
        func typeSlowly(_ text: String, delay: TimeInterval = 0.08) {
            for char in text {
                searchField.typeText(String(char))
                Thread.sleep(forTimeInterval: delay)
            }
        }

        // Helper to clear search field
        func clearSearch() {
            searchField.typeKey("a", modifierFlags: .command)  // Select all
            searchField.typeKey(.delete, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.3)
        }

        // ============================================================
        // SCENE 1: Meta Pitch - Fuzzy search refinement (0:00 - 0:08)
        // ============================================================

        // 0:00 - Initial pause (ensure recording has captured initial state)
        Thread.sleep(forTimeInterval: 1.0)

        // Type "h"
        typeSlowly("h")
        Thread.sleep(forTimeInterval: 0.8)

        // Continue to "hello"
        typeSlowly("ello")
        Thread.sleep(forTimeInterval: 0.8)

        // Continue to "hello clip"
        typeSlowly(" clip")
        Thread.sleep(forTimeInterval: 1.5)

        // ============================================================
        // SCENE 2: Color and Image Preview (0:08 - 0:14)
        // ============================================================

        // Scene 2
        clearSearch()
        Thread.sleep(forTimeInterval: 0.3)

        typeSlowly("#")
        Thread.sleep(forTimeInterval: 0.5)

        typeSlowly("f")
        Thread.sleep(forTimeInterval: 0.8)

        clearSearch()
        typeSlowly("cat")
        Thread.sleep(forTimeInterval: 2.0)

        // ============================================================
        // SCENE 3: Typo Forgiveness, Six Months Deep (0:14 - 0:20)
        // ============================================================

        // Scene 3
        clearSearch()
        Thread.sleep(forTimeInterval: 0.3)

        typeSlowly("r")
        Thread.sleep(forTimeInterval: 0.3)

        typeSlowly("iv")
        Thread.sleep(forTimeInterval: 0.5)

        typeSlowly("resid")
        Thread.sleep(forTimeInterval: 1.5)

        clearSearch()
        Thread.sleep(forTimeInterval: 0.5)

        // Signal that the demo is finished
        try? "stop".write(toFile: "/tmp/clipkitty_demo_stop.txt", atomically: true, encoding: .utf8)
    }

    /// Captures multiple screenshot states for marketing materials.
    /// Run with: make marketing-screenshots
    /// NOTE: Relies entirely on demo items in SyntheticData.sqlite (generated with --demo flag)
    func testTakeMarketingScreenshots() throws {
        let searchField = app.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field not found")

        // Cycle the panel: hide then re-show to ensure clean visual state
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(" ", modifierFlags: .option)
        let panel = app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "Panel should reappear after hotkey toggle")
        Thread.sleep(forTimeInterval: 0.5)

        // Screenshot 1: Initial state showing clipboard history
        Thread.sleep(forTimeInterval: 1.0)
        saveScreenshot(name: "marketing_1_history")

        // Screenshot 2: Fuzzy search in action (typo-tolerant: "dockr"→docker, "prodction"→production, spanning multiple lines)
        searchField.click()
        searchField.typeText("dockr push prodction")
        Thread.sleep(forTimeInterval: 0.5)
        saveScreenshot(name: "marketing_2_search")

        // Screenshot 3: Images filter applied with dropdown still open
        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeKey(.delete, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        let filterButton = app.buttons["FilterDropdown"]
        // First apply the Images filter
        filterButton.click()
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        // Re-open the dropdown so it's visible in the screenshot
        filterButton.click()
        Thread.sleep(forTimeInterval: 0.5)
        saveScreenshot(name: "marketing_3_filter")
    }
}
