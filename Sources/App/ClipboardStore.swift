import Foundation
import AppKit
import Observation
import ClipKittyRust
import QuartzCore
import os

import ImageIO
import UniformTypeIdentifiers

// MARK: - Background Operation Helpers

/// Execute a database operation on a background thread and return the result.
/// Uses structured concurrency with proper Sendable handling for the Rust store.
private func runInBackground<T: Sendable>(
    _ operation: String,
    on store: ClipKittyRust.ClipboardStore,
    body: @escaping @Sendable (ClipKittyRust.ClipboardStore) throws -> T
) async -> Result<T, ClipboardError> {
    // The Rust store is @unchecked Sendable, so we can safely capture it
    do {
        let result = try await Task.detached(priority: .userInitiated) {
            try body(store)
        }.value
        return .success(result)
    } catch {
        return .failure(.databaseOperationFailed(operation: operation, underlying: error))
    }
}

/// Execute a database operation on a background thread, ignoring the result.
/// Logs errors via ErrorReporter and optionally shows a toast.
@MainActor
private func runInBackgroundIgnoringResult(
    _ operation: String,
    on store: ClipKittyRust.ClipboardStore,
    showToast: Bool = false,
    body: @escaping @Sendable (ClipKittyRust.ClipboardStore) throws -> Void
) {
    Task.detached(priority: .utility) {
        do {
            try body(store)
        } catch {
            await ErrorReporter.report(
                ClipboardError.databaseOperationFailed(operation: operation, underlying: error),
                showToast: showToast
            )
        }
    }
}

// MARK: - Logging

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ClipKitty", category: "ClipboardStore")

/// Display state for the clipboard list
/// Search with empty query returns all items (what was previously called "browse mode")
enum DisplayState: Equatable {
    /// Initial loading state before any data
    case loading
    /// Results ready - query can be empty (all items) or non-empty (filtered)
    /// Includes optional first item for immediate preview display
    case results(query: String, items: [ItemMatch], firstItem: ClipboardItem?)
    /// Loading in progress - showing fallback results while waiting for new results
    /// Preserves match highlights from previous search to prevent text flash
    case resultsLoading(query: String, fallback: [ItemMatch])
    /// Error state
    case error(String)
}

@MainActor
@Observable
final class ClipboardStore {
    // MARK: - State (Single Source of Truth)

    private(set) var state: DisplayState = .loading

    /// Whether currently showing results (not in initial loading or error state)
    var hasResults: Bool {
        switch state {
        case .results, .resultsLoading:
            return true
        case .loading, .error:
            return false
        }
    }

    /// Current query (empty string if showing all items)
    var currentQuery: String {
        switch state {
        case .results(let query, _, _), .resultsLoading(let query, _):
            return query
        case .loading, .error:
            return ""
        }
    }

    /// Current content type filter (observable by views)
    private(set) var contentTypeFilter: ContentTypeFilter = .all

    // MARK: - Private State

    /// Rust-backed clipboard store
    private var rustStore: ClipKittyRust.ClipboardStore?

    private var lastChangeCount: Int = 0
    private var pollingTask: Task<Void, Never>?

    // MARK: - Adaptive Polling State

    private enum SystemSleepMonitoring {
        case notMonitoring
        case monitoring(sleepObserver: NSObjectProtocol, wakeObserver: NSObjectProtocol, isAsleep: Bool)

        var isAsleep: Bool {
            switch self {
            case .notMonitoring:
                return false
            case .monitoring(_, _, let isAsleep):
                return isAsleep
            }
        }

        mutating func setAsleep(_ asleep: Bool) {
            guard case .monitoring(let sleep, let wake, _) = self else { return }
            self = .monitoring(sleepObserver: sleep, wakeObserver: wake, isAsleep: asleep)
        }
    }

    private var lastActivityTime: Date = Date()
    private var sleepMonitoring: SystemSleepMonitoring = .notMonitoring
    private var searchTask: Task<Void, Never>?
    /// Current search query
    private var currentSearchQuery: String = ""
    /// Query-scoped lazy match-data loads currently in flight.
    private var inFlightMatchDataLoads: Set<MatchDataLoadRequest> = []

    /// Increments each time the display is reset - views observe this to reset local state
    /// Uses Int which will overflow after ~2 billion increments, but this is acceptable
    /// as the counter only needs to detect changes, not maintain absolute ordering
    private(set) var displayVersion: Int = 0

    /// Link metadata fetcher using LinkPresentation framework
    private let linkMetadataFetcher = LinkMetadataFetcher()

    /// Pasteboard for clipboard operations (injected for testability)
    private let pasteboard: PasteboardProtocol

    private struct MatchDataLoadRequest: Hashable {
        let itemId: Int64
        let query: String
    }

    // MARK: - Initialization

    private let isScreenshotMode: Bool

    init(screenshotMode: Bool = false, pasteboard: PasteboardProtocol = NSPasteboard.general) {
        self.isScreenshotMode = screenshotMode
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
        setupDatabase()
        refresh()
        pruneIfNeeded()
    }

    /// Current database size in bytes (cached, updated async)
    private(set) var databaseSizeBytes: Int64 = 0

    /// Refresh database size asynchronously
    func refreshDatabaseSize() {
        guard let rustStore else { return }
        Task {
            let result = await runInBackground("databaseSize", on: rustStore) { store in
                store.databaseSize()
            }
            if case .success(let size) = result {
                self.databaseSizeBytes = size
            }
        }
    }

    // MARK: - Database Setup

    /// Returns the database filename based on mode
    static func databaseFilename(screenshotMode: Bool) -> String {
        screenshotMode ? "clipboard-screenshot.sqlite" : "clipboard.sqlite"
    }

    private func setupDatabase() {
        do {
            guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                let error = ClipboardError.databaseInitFailed(underlying: NSError(domain: "ClipKitty", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to locate application support directory"]))
                ErrorReporter.reportCritical(error)
                state = .error(error.localizedDescription)
                return
            }
            let appDir = appSupport.appendingPathComponent("ClipKitty", isDirectory: true)
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

            let dbPath = appDir.appendingPathComponent(Self.databaseFilename(screenshotMode: isScreenshotMode)).path

            // Initialize the Rust store
            rustStore = try ClipKittyRust.ClipboardStore(dbPath: dbPath)
        } catch {
            let dbError = ClipboardError.databaseInitFailed(underlying: error)
            ErrorReporter.reportCritical(dbError)
            state = .error(dbError.localizedDescription)
        }
    }

    // MARK: - Public API

    func setSearchQuery(_ newQuery: String) {
        let query = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        // Cancel previous search task. Note: cancelled tasks may still complete their
        // Rust search operation, but will be discarded in performSearch() via query check.
        searchTask?.cancel()
        currentSearchQuery = query

        // Capture fallback results from current state (preserves match text to prevent flash)
        let fallback: [ItemMatch] = {
            switch state {
            case .results(_, let items, _), .resultsLoading(_, let items):
                return items
            case .loading, .error:
                return []
            }
        }()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        state = .resultsLoading(query: query, fallback: fallback)
        CATransaction.commit()

        searchTask = Task {
            // Small debounce for typed queries
            if !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
            }
            await performSearch(query: query)
        }
    }

    func resetForDisplay() {
        searchTask?.cancel()
        contentTypeFilter = .all
        displayVersion += 1
        refresh()
    }

    func setContentTypeFilter(_ filter: ContentTypeFilter) {
        contentTypeFilter = filter
        refresh()
    }

    /// Fetch full ClipboardItem by ID
    func fetchItem(id: Int64) async -> ClipboardItem? {
        guard let rustStore else { return nil }
        let result = await runInBackground("fetchItem", on: rustStore) { store in
            try store.fetchByIds(itemIds: [id])
        }
        if case .success(let items) = result {
            return items.first
        }
        return nil
    }

    /// Compute highlights for visible items (called on-demand as rows become visible)
    /// Returns MatchData array in same order as input IDs, or empty array on error
    func computeHighlights(itemIds: [Int64], query: String) -> [MatchData] {
        guard let rustStore else { return [] }
        return (try? rustStore.computeHighlights(itemIds: itemIds, query: query)) ?? []
    }

    /// Compute and merge match data for items that do not have it yet.
    /// Results are merged in place so the list does not need a full search refresh.
    func loadMatchDataForItems(itemIds: [Int64]) {
        guard case .results(let query, let items, _) = state,
              !query.isEmpty,
              !itemIds.isEmpty,
              let rustStore else { return }

        var seenIds: Set<Int64> = []
        let uniqueItemIds = itemIds.filter { seenIds.insert($0).inserted }
        let requests = uniqueItemIds.map { MatchDataLoadRequest(itemId: $0, query: query) }

        let idsNeedingData = requests.compactMap { request -> Int64? in
            guard !inFlightMatchDataLoads.contains(request),
                  items.first(where: { $0.itemMetadata.itemId == request.itemId })?.matchData == nil else {
                return nil
            }
            return request.itemId
        }
        guard !idsNeedingData.isEmpty else { return }

        let activeRequests = Set(idsNeedingData.map { MatchDataLoadRequest(itemId: $0, query: query) })
        inFlightMatchDataLoads.formUnion(activeRequests)

        Task { [weak self] in
            guard let self else { return }

            let result = await runInBackground("computeHighlights", on: rustStore) { store in
                try store.computeHighlights(itemIds: idsNeedingData, query: query)
            }

            self.inFlightMatchDataLoads.subtract(activeRequests)

            switch result {
            case .failure(let error):
                ErrorReporter.report(error, showToast: false)
                return
            case .success(let matchDataResults):
                guard matchDataResults.count == idsNeedingData.count else { return }
                guard case .results(let currentQuery, var currentItems, let firstItem) = self.state,
                      currentQuery == query else { return }

                var idToMatchData: [Int64: MatchData] = [:]
                for (index, itemId) in idsNeedingData.enumerated() {
                    idToMatchData[itemId] = matchDataResults[index]
                }

                var didChange = false
                for index in currentItems.indices {
                    let itemId = currentItems[index].itemMetadata.itemId
                    guard currentItems[index].matchData == nil,
                          let matchData = idToMatchData[itemId] else { continue }
                    currentItems[index] = ItemMatch(
                        itemMetadata: currentItems[index].itemMetadata,
                        matchData: matchData
                    )
                    didChange = true
                }

                guard didChange else { return }

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.state = .results(query: currentQuery, items: currentItems, firstItem: firstItem)
                CATransaction.commit()
            }
        }
    }

    /// Fetch link metadata using LinkPresentation and persist to database
    /// Returns the updated item if successful
    func fetchLinkMetadata(url: String, itemId: Int64) async -> ClipboardItem? {
        guard let rustStore else { return nil }

        // Fetch metadata using LinkPresentation framework
        guard let metadata = await linkMetadataFetcher.fetchMetadata(for: url, itemId: itemId) else {
            // Mark as failed
            _ = await runInBackground("updateLinkMetadata", on: rustStore) { store in
                try store.updateLinkMetadata(
                    itemId: itemId,
                    title: "",
                    description: nil,
                    imageData: nil
                )
            }
            return await fetchItem(id: itemId)
        }

        // Persist to database (await to ensure write completes before read)
        let imageData = metadata.imageData
        _ = await runInBackground("updateLinkMetadata", on: rustStore) { store in
            try store.updateLinkMetadata(
                itemId: itemId,
                title: metadata.title,
                description: metadata.description,
                imageData: imageData
            )
        }

        // Return updated item
        return await fetchItem(id: itemId)
    }

    // MARK: - Refresh

    /// Refresh items with current query (convenience for reload scenarios)
    private func refresh() {
        setSearchQuery(currentSearchQuery)
    }

    private func performSearch(query: String) async {
        guard let rustStore else {
            state = .error(String(localized: "Database not available"))
            return
        }

        do {
            let searchResult: SearchResult
            if contentTypeFilter != .all {
                searchResult = try await rustStore.searchFiltered(query: query, filter: contentTypeFilter)
            } else {
                searchResult = try await rustStore.search(query: query)
            }

            guard !Task.isCancelled else { return }
            // Verify we're still showing results for this query (acts as generation check).
            // If the query changed while we were searching, a newer search is already running.
            guard case .resultsLoading(let currentQuery, _) = state, currentQuery == query else { return }

            // Capture old state before replacing - deallocation of large arrays can block main thread
            let oldState = state
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            state = .results(query: query, items: searchResult.matches, firstItem: searchResult.firstItem)
            CATransaction.commit()

            // Defer deallocation of old state to background queue
            Task.detached(priority: .background) {
                _ = oldState  // Force capture and release on background thread
            }
        } catch ClipKittyError.Cancelled {
            // Search was cancelled - this is normal, not an error
        } catch {
            guard !Task.isCancelled else { return }
            let searchError = ClipboardError.databaseOperationFailed(operation: "search", underlying: error)
            ErrorReporter.report(searchError, showToast: false)
            state = .error(searchError.localizedDescription)
        }
    }

    // MARK: - Clipboard Monitoring

    func startMonitoring() {
        pollingTask?.cancel()
        setupSystemObservers()

        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                // Skip polling entirely while system is sleeping
                if self.sleepMonitoring.isAsleep {
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }

                self.checkForChanges()
                let interval = self.adaptivePollingInterval()
                try? await Task.sleep(for: .milliseconds(interval))
            }
        }
    }

    func stopMonitoring() {
        pollingTask?.cancel()
        pollingTask = nil
        removeSystemObservers()
    }

    private func setupSystemObservers() {
        let workspace = NSWorkspace.shared
        let nc = workspace.notificationCenter

        let sleepObs = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sleepMonitoring.setAsleep(true)
            }
        }

        let wakeObs = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sleepMonitoring.setAsleep(false)
                // Brief burst of faster polling after wake to catch any changes
                self?.lastActivityTime = Date()
            }
        }

        sleepMonitoring = .monitoring(sleepObserver: sleepObs, wakeObserver: wakeObs, isAsleep: false)
    }

    private func removeSystemObservers() {
        guard case .monitoring(let sleepObs, let wakeObs, _) = sleepMonitoring else { return }

        let nc = NSWorkspace.shared.notificationCenter
        nc.removeObserver(sleepObs)
        nc.removeObserver(wakeObs)

        sleepMonitoring = .notMonitoring
    }

    /// Returns polling interval in milliseconds based on system state and activity.
    /// NOTE: Uses wall clock time (Date()) which can be affected by system time changes.
    /// This is acceptable for polling intervals - worst case is a single incorrect interval.
    private func adaptivePollingInterval() -> Int {
        let idleTime = Date().timeIntervalSince(lastActivityTime)

        // Low power mode: always use slower polling
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return 2000
        }

        // Adaptive based on idle time
        switch idleTime {
        case ..<5:
            // Recently active: fast polling for responsiveness
            return 250
        case ..<30:
            // Normal usage: balanced polling
            return 500
        case ..<120:
            // Idle: reduce polling frequency
            return 1000
        default:
            // Long idle: minimal polling
            return 1500
        }
    }

    private func checkForChanges() {
        // Note: Uses NSPasteboard.general directly since readObjects is not in the protocol
        // The injected pasteboard is used for paste operations (testable)
        let systemPasteboard = NSPasteboard.general
        let currentCount = systemPasteboard.changeCount

        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        // User is actively copying - enable faster polling
        lastActivityTime = Date()

        let settings = AppSettings.shared

        // Check if the source app is ignored
        let sourceAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if settings.isAppIgnored(bundleId: sourceAppBundleID) {
            return
        }

        // Skip concealed/sensitive content (e.g. passwords from 1Password, Bitwarden)
        if settings.ignoreConfidentialContent {
            let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
            if systemPasteboard.data(forType: concealedType) != nil {
                return
            }
        }

        // Skip transient content (temporary data from apps)
        if settings.ignoreTransientContent {
            let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
            if systemPasteboard.data(forType: transientType) != nil {
                return
            }
        }

        // Check for file URLs first (file copies also put .tiff and .string on the pasteboard)
        if let fileURLs = systemPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !fileURLs.isEmpty {
            saveFileItems(urls: fileURLs)
            return
        }

        // Check for GIF first (preserve animation), then fall back to static image types
        let gifType = NSPasteboard.PasteboardType("com.compuserve.gif")
        if let gifData = systemPasteboard.data(forType: gifType) {
            saveImageItem(rawImageData: gifData, isAnimated: true)
            return
        }

        // Check for static image data - get raw data only, defer compression
        let imageTypes: [NSPasteboard.PasteboardType] = [.tiff, .png]
        for type in imageTypes {
            if let rawData = systemPasteboard.data(forType: type) {
                saveImageItem(rawImageData: rawData, isAnimated: false)
                return
            }
        }

        // Otherwise check for text
        guard let text = systemPasteboard.string(forType: .string), !text.isEmpty else { return }

        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName

        // Move all DB operations to background
        guard let rustStore else { return }
        Task {
            let result = await runInBackground("saveText", on: rustStore) { store in
                // Rust handles URL detection and metadata fetching automatically
                try store.saveText(text: text, sourceApp: sourceApp, sourceAppBundleId: sourceAppBundleID)
            }

            switch result {
            case .success(let itemId):
                // Reload if in browse mode
                if self.hasResults {
                    self.refresh()
                }

                // If this is a new item (not duplicate) and looks like a URL, prefetch link metadata
                // Only if link previews are enabled in privacy settings
                if itemId > 0, URL(string: text) != nil, text.hasPrefix("http") {
                    guard AppSettings.shared.generateLinkPreviews else { return }
                    _ = await self.fetchLinkMetadata(url: text, itemId: itemId)
                    if self.hasResults {
                        self.refresh()
                    }
                }

            case .failure(let error):
                ErrorReporter.report(error, showToast: false)
            }
        }
    }


    private func generateAndUpdateImageDescription(itemId: Int64, imageData: Data) async {
        guard let description = await ImageDescriptionGenerator.generateDescription(from: imageData) else { return }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let rustStore else { return }
        let result = await runInBackground("updateImageDescription", on: rustStore) { store in
            try store.updateImageDescription(itemId: itemId, description: trimmed)
        }

        if case .failure(let error) = result {
            ErrorReporter.report(error, showToast: false)
        }

        if self.hasResults {
            self.refresh()
        }
    }

    /// Save text that was edited in the preview pane.
    /// Uses "ClipKitty" as source app since the edit happened within the app.
    /// Returns new item ID, or 0 if duplicate (timestamp updated).
    func saveEditedText(text: String) async -> Int64 {
        guard let rustStore else { return 0 }

        let result = await runInBackground("saveEditedText", on: rustStore) { store in
            try store.saveText(
                text: text,
                sourceApp: "ClipKitty",
                sourceAppBundleId: Bundle.main.bundleIdentifier
            )
        }

        switch result {
        case .success(let itemId):
            return itemId
        case .failure(let error):
            ErrorReporter.report(error, showToast: false)
            return 0
        }
    }

    private func saveImageItem(rawImageData: Data, isAnimated: Bool) {
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        let sourceAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let maxPixels = Int(AppSettings.shared.maxImageMegapixels * 1_000_000)
        let quality = AppSettings.shared.imageCompressionQuality

        // Move compression and DB write to background
        guard let rustStore else { return }
        Task {
            // Process image on background thread using ImageIngestService
            let ingestResult: ImageIngestResult? = await withCheckedContinuation { continuation in
                Task.detached(priority: .userInitiated) {
                    let result = ImageIngestService.processImage(
                        rawData: rawImageData,
                        isAnimated: isAnimated,
                        quality: quality,
                        maxPixels: maxPixels
                    )
                    continuation.resume(returning: result)
                }
            }

            guard let result = ingestResult else {
                ErrorReporter.report(ClipboardError.imageCompressionFailed, showToast: false)
                return
            }

            // Save to database
            let saveResult = await runInBackground("saveImage", on: rustStore) { store in
                try store.saveImage(
                    imageData: result.compressedData,
                    thumbnail: result.thumbnail,
                    sourceApp: sourceApp,
                    sourceAppBundleId: sourceAppBundleID,
                    isAnimated: result.isAnimated
                )
            }

            switch saveResult {
            case .success(let itemId):
                if self.hasResults {
                    self.refresh()
                }

                // Generate image description in background
                Task {
                    await self.generateAndUpdateImageDescription(itemId: itemId, imageData: result.compressedData)
                }

            case .failure(let error):
                ErrorReporter.report(error, showToast: false)
            }
        }
    }

    // MARK: - File Items

    private func saveFileItems(urls: [URL]) {
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        let sourceAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        guard let rustStore else { return }
        Task {
            // Collect file metadata (CPU-bound, safe to run on any thread)
            var paths: [String] = []
            var filenames: [String] = []
            var fileSizes: [UInt64] = []
            var utis: [String] = []
            var bookmarkDataList: [Data] = []

            for url in urls {
                guard url.isFileURL else { continue }

                paths.append(url.path)
                filenames.append(url.lastPathComponent)

                let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                fileSizes.append(UInt64(resourceValues?.fileSize ?? 0))

                let isDirectory = resourceValues?.isDirectory == true
                if isDirectory {
                    utis.append("public.folder")
                } else {
                    utis.append(UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.item")
                }

                // NOTE: Bookmark data is always empty in sandboxed mode (App Store build).
                // Security-scoped bookmarks require user-initiated file selection via NSOpenPanel.
                // For clipboard monitoring, we use direct file paths which are accessible while the app is running.
                bookmarkDataList.append(Data())
            }

            guard !paths.isEmpty else { return }

            let result = await runInBackground("saveFiles", on: rustStore) { store in
                try store.saveFiles(
                    paths: paths,
                    filenames: filenames,
                    fileSizes: fileSizes,
                    utis: utis,
                    bookmarkDataList: bookmarkDataList,
                    thumbnail: nil,
                    sourceApp: sourceApp,
                    sourceAppBundleId: sourceAppBundleID
                )
            }

            switch result {
            case .success:
                if self.hasResults {
                    self.refresh()
                }
            case .failure(let error):
                ErrorReporter.report(error, showToast: false)
            }
        }
    }

    // MARK: - Actions

    func paste(itemId: Int64, content: ClipboardContent) {
        // Handle images differently - convert off main thread
        if case .image(let data, _, let isAnimated) = content {
            pasteImage(data: Data(data), isAnimated: isAnimated, itemId: itemId)
            return
        }

        if case .file(_, let files) = content {
            pasteFiles(files: files, itemId: itemId)
            return
        }

        pasteboard.clearContents()
        pasteboard.setString(content.textContent, forType: .string)
        lastChangeCount = pasteboard.changeCount

        Task { [weak self] in
            await self?.updateItemTimestamp(id: itemId)
        }
    }

    private func pasteImage(data: Data, isAnimated: Bool, itemId: Int64?) {
        // Pre-increment to avoid race with checkForChanges polling
        // The pasteboard changeCount will increment when we set data
        lastChangeCount = pasteboard.changeCount + 1

        Task {
            if isAnimated {
                // Convert animated HEIC to GIF for pasting (CPU-intensive, use background)
                let gifData: Data? = await withCheckedContinuation { continuation in
                    Task.detached(priority: .userInitiated) {
                        continuation.resume(returning: ImageIngestService.convertAnimatedHEICToGIF(data))
                    }
                }

                guard let gifData else {
                    self.lastChangeCount = self.pasteboard.changeCount
                    return
                }

                self.pasteboard.clearContents()
                self.pasteboard.setData(gifData, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
                // Also provide TIFF fallback for apps that don't support GIF
                if let image = NSImage(data: data), let tiff = image.tiffRepresentation {
                    self.pasteboard.setData(tiff, forType: .tiff)
                }
            } else {
                // Convert from stored format (HEIC) to TIFF off main thread
                let tiffData: Data? = await withCheckedContinuation { continuation in
                    Task.detached(priority: .userInitiated) {
                        guard let image = NSImage(data: data),
                              let tiff = image.tiffRepresentation else {
                            continuation.resume(returning: nil)
                            return
                        }
                        continuation.resume(returning: tiff)
                    }
                }

                guard let tiffData else {
                    self.lastChangeCount = self.pasteboard.changeCount
                    return
                }

                self.pasteboard.clearContents()
                self.pasteboard.setData(tiffData, forType: .tiff)
            }

            self.lastChangeCount = self.pasteboard.changeCount

            if let itemId {
                await self.updateItemTimestamp(id: itemId)
            }
        }
    }

    private func pasteFiles(files: [FileEntry], itemId: Int64) {
        // Pre-increment to avoid race with checkForChanges polling
        lastChangeCount = pasteboard.changeCount + 1

        // Resolve each file's bookmark to get current URL
        var resolvedURLs: [URL] = []
        for file in files {
            // Use stored path directly (no bookmark data in sandboxed mode)
            resolvedURLs.append(URL(fileURLWithPath: file.path))
        }

        guard !resolvedURLs.isEmpty else { return }

        // Write to pasteboard with both modern and legacy types for broad compatibility.
        // Finder requires NSFilenamesPboardType for file paste; other apps use public.file-url.
        let filenameType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        let allPaths = resolvedURLs.map { $0.path }
        pasteboard.declareTypes([filenameType, .fileURL, .string], owner: nil)
        pasteboard.setPropertyList(allPaths, forType: filenameType)  // All files (array)
        pasteboard.setString(resolvedURLs[0].absoluteString, forType: .fileURL)  // First file only (.fileURL is singular)
        pasteboard.setString(allPaths.joined(separator: "\n"), forType: .string)  // All files (text)
        lastChangeCount = pasteboard.changeCount

        Task { [weak self] in
            await self?.updateItemTimestamp(id: itemId)
        }
    }

    private func updateItemTimestamp(id: Int64) async {
        guard let rustStore else { return }
        // Defer database operations to avoid blocking clipboard availability
        let result = await runInBackground("updateTimestamp", on: rustStore) { store in
            try store.updateTimestamp(itemId: id)
        }

        // Log any errors but don't show toast (timestamp update is non-critical)
        if case .failure(let error) = result {
            ErrorReporter.report(error, showToast: false)
        }

        // Reload if in browse mode
        if hasResults {
            refresh()
        }
    }

    /// Execute a background operation with rollback on failure
    private func runWithRollback<T: Sendable>(
        _ operation: String,
        snapshot: DisplayState,
        on store: ClipKittyRust.ClipboardStore,
        body: @escaping @Sendable (ClipKittyRust.ClipboardStore) throws -> T
    ) async -> Result<T, ClipboardError> {
        let result = await runInBackground(operation, on: store, body: body)

        switch result {
        case .success(let value):
            return .success(value)
        case .failure(let error):
            // Rollback state to snapshot
            self.state = snapshot

            // Report error with toast
            await ErrorReporter.report(error, showToast: true)

            return .failure(error)
        }
    }

    func delete(itemId: Int64) {
        // Capture state snapshot BEFORE modifying
        let snapshot = state

        // Update UI immediately (optimistic update)
        switch state {
        case .results(let query, let items, let firstItem):
            let filteredItems = items.filter { $0.itemMetadata.itemId != itemId }
            let newFirstItem = firstItem?.itemMetadata.itemId == itemId ? nil : firstItem
            state = .results(query: query, items: filteredItems, firstItem: newFirstItem)
        case .resultsLoading(let query, let fallback):
            state = .resultsLoading(
                query: query,
                fallback: fallback.filter { $0.itemMetadata.itemId != itemId }
            )
        case .loading, .error:
            break
        }

        // Perform DB delete in background with rollback on failure
        guard let rustStore else { return }
        Task {
            _ = await runWithRollback("deleteItem", snapshot: snapshot, on: rustStore) { store in
                try store.deleteItem(itemId: itemId)
            }
        }
    }

    func clear() {
        // Capture state snapshot BEFORE modifying
        let snapshot = state

        // Update UI immediately (optimistic update)
        state = .results(query: "", items: [], firstItem: nil)

        // Perform DB clear in background with rollback on failure
        guard let rustStore else { return }
        Task {
            _ = await runWithRollback("clear", snapshot: snapshot, on: rustStore) { store in
                try store.clear()
            }
        }
    }

    // MARK: - Pruning

    func pruneIfNeeded() {
        let maxSizeGB = AppSettings.shared.maxDatabaseSizeGB
        guard maxSizeGB > 0, let rustStore else { return }

        let maxBytes = Int64(maxSizeGB * 1024 * 1024 * 1024)

        runInBackgroundIgnoringResult("pruneToSize", on: rustStore) { store in
            _ = try store.pruneToSize(maxBytes: maxBytes, keepRatio: 0.8)
        }
    }
}
