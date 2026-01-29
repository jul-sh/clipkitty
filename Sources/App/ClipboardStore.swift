import Foundation
import AppKit
import Observation
import ClipKittyRust
import os.signpost
import os.log
import ImageIO

// MARK: - Performance Tracing

private let performanceLog = OSLog(subsystem: "com.clipkitty.app", category: "Performance")
private let logger = Logger(subsystem: "com.clipkitty.app", category: "Performance")

private enum TraceID {
    static let loadItems = OSSignpostID(log: performanceLog)
    static let search = OSSignpostID(log: performanceLog)
    static let metadata = OSSignpostID(log: performanceLog)
}

/// Simple timing helper - uses os_log for reliable capture
private func measureTime<T>(_ label: String, _ block: () throws -> T) rethrows -> T {
    let start = CFAbsoluteTimeGetCurrent()
    let result = try block()
    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
    os_log(.default, log: performanceLog, "%{public}s: %.2fms", label, elapsed)
    return result
}

private func measureTimeAsync<T>(_ label: String, _ block: () async throws -> T) async rethrows -> T {
    let start = CFAbsoluteTimeGetCurrent()
    let result = try await block()
    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
    os_log(.default, log: performanceLog, "%{public}s: %.2fms", label, elapsed)
    return result
}

/// Search result item with highlights
struct SearchResultItem: Equatable {
    let item: ClipboardItem
    let highlights: [HighlightRange]
}

/// Search result state - makes loading/results states explicit
enum SearchResultState: Equatable {
    case loading(previousResults: [SearchResultItem])
    case results([SearchResultItem], hasMore: Bool)
}

/// Combined state for data display
enum DisplayState: Equatable {
    case loading
    case loaded(items: [ClipboardItem], hasMore: Bool)
    case searching(query: String, state: SearchResultState)
    case error(String)
}

@MainActor
@Observable
final class ClipboardStore {
    // MARK: - State (Single Source of Truth)

    private(set) var state: DisplayState = .loading

    // MARK: - Private State

    /// Rust-backed clipboard store
    private var rustStore: ClipKittyRust.ClipboardStore?

    private var lastChangeCount: Int = 0
    private var pollingTask: Task<Void, Never>?

    // MARK: - Adaptive Polling State
    private var lastActivityTime: Date = Date()
    private var isSystemSleeping: Bool = false
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var searchTask: Task<Void, Never>?
    /// Cursor for keyset pagination - timestamp of the oldest loaded item (unix)
    private var oldestLoadedTimestampUnix: Int64?
    /// Current search query (for pagination continuity)
    private var currentSearchQuery: String = ""
    private let pageSize: UInt64 = 50

    /// Increments each time the display is reset - views observe this to reset local state
    private(set) var displayVersion: Int = 0

    // MARK: - Initialization

    private let isScreenshotMode: Bool

    init(screenshotMode: Bool = false) {
        self.isScreenshotMode = screenshotMode
        lastChangeCount = NSPasteboard.general.changeCount
        setupDatabase()
        loadItems(reset: true)
        pruneIfNeeded()
        verifyFTSIntegrityAsync()
    }

    /// Check FTS index integrity in background and rebuild if needed
    private func verifyFTSIntegrityAsync() {
        guard let rustStore else { return }
        Task.detached {
            let needsRebuild = !rustStore.verifyFtsIntegrity()
            if needsRebuild {
                // FTS rebuild happens automatically via verifyFtsIntegrity
                logError("FTS index was rebuilt")
            }
        }
    }

    /// Current database size in bytes (cached, updated async)
    private(set) var databaseSizeBytes: Int64 = 0

    /// Refresh database size asynchronously
    func refreshDatabaseSize() {
        guard let rustStore else { return }
        Task.detached {
            let size = rustStore.databaseSize()
            await MainActor.run { [weak self] in
                self?.databaseSizeBytes = size
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
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let appDir = appSupport.appendingPathComponent("ClipKitty", isDirectory: true)
            let legacyDir = appSupport.appendingPathComponent("PaperTrail", isDirectory: true)

            if FileManager.default.fileExists(atPath: legacyDir.path),
               !FileManager.default.fileExists(atPath: appDir.path) {
                try FileManager.default.moveItem(at: legacyDir, to: appDir)
            } else {
                try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            }

            let dbPath = appDir.appendingPathComponent(Self.databaseFilename(screenshotMode: isScreenshotMode)).path

            // Initialize the Rust store
            rustStore = try ClipKittyRust.ClipboardStore(dbPath: dbPath)
        } catch {
            state = .error("Database setup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Public API

    func setSearchQuery(_ newQuery: String) {
        let query = newQuery

        searchTask?.cancel()

        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            currentSearchQuery = ""
            loadItems(reset: true)
            return
        }

        currentSearchQuery = query

        // Preserve previous results while loading new ones to avoid UI flash.
        // When new results arrive, they fully replace previous results (no mixing).
        let previousResults: [SearchResultItem] = {
            switch state {
            case .searching(_, let searchState):
                switch searchState {
                case .loading(let previous):
                    return previous
                case .results(let results, _):
                    return results
                }
            case .loaded(let items, _):
                // Convert loaded items to search results (no highlights yet)
                return items.map { SearchResultItem(item: $0, highlights: []) }
            default:
                return []
            }
        }()

        state = .searching(query: query, state: .loading(previousResults: previousResults))

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            await performSearch(query: query)
        }
    }

    func loadMoreItems() {
        guard case .loaded(_, true) = state else { return }
        loadItems(reset: false)
    }

    func resetForDisplay() {
        searchTask?.cancel()
        displayVersion += 1
        loadItems(reset: true)
    }

    /// Reset selection state for a new display session (called on show)
    func prepareForDisplay() {
        searchTask?.cancel()
        displayVersion += 1
    }

    /// Fetch link metadata on-demand if not already loaded
    func fetchLinkMetadataIfNeeded(for item: ClipboardItem) {
        // Only fetch for links with pending metadata
        guard case .link(let url, let metadataState) = item.content,
              case .pending = metadataState,
              let id = item.id else { return }

        Task {
            await fetchAndUpdateLinkMetadata(for: id, url: url)
        }
    }

    // MARK: - Loading

    private func loadItems(reset: Bool) {
        let cursorTimestamp: Int64?
        let existingItems: [ClipboardItem]

        // Extract current items from any state to preserve during refresh
        let currentItems: [ClipboardItem] = {
            switch state {
            case .loaded(let items, _):
                return items
            case .searching(_, let searchState):
                switch searchState {
                case .loading(let previous):
                    return previous.map { $0.item }
                case .results(let results, _):
                    return results.map { $0.item }
                }
            default:
                return []
            }
        }()

        if reset {
            oldestLoadedTimestampUnix = nil
            cursorTimestamp = nil
            existingItems = []
            // Only show loading spinner if we have no cached items to display
            if currentItems.isEmpty {
                state = .loading
            }
        } else {
            cursorTimestamp = oldestLoadedTimestampUnix
            if case .loaded(let items, _) = state {
                existingItems = items
            } else {
                existingItems = []
            }
        }

        guard let rustStore else { return }
        let pageSizeCopy = pageSize
        let signpostID = OSSignpostID(log: performanceLog)
        os_signpost(.begin, log: performanceLog, name: "loadItems", signpostID: signpostID, "reset=%d", reset ? 1 : 0)

        Task.detached {
            do {
                let result = try rustStore.fetchItems(beforeTimestampUnix: cursorTimestamp, limit: pageSizeCopy)

                await MainActor.run { [weak self] in
                    os_signpost(.end, log: performanceLog, name: "loadItems", signpostID: signpostID)
                    // Update cursor to oldest item's timestamp for next page
                    if let oldestItem = result.items.last {
                        self?.oldestLoadedTimestampUnix = oldestItem.timestampUnix
                    }
                    if reset {
                        self?.state = .loaded(items: result.items, hasMore: result.hasMore)
                    } else {
                        self?.state = .loaded(items: existingItems + result.items, hasMore: result.hasMore)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    os_signpost(.end, log: performanceLog, name: "loadItems", signpostID: signpostID, "error")
                    self?.state = .error("Failed to load items: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Search
    //
    // ════════════════════════════════════════════════════════════════════════════════
    // SEARCH ARCHITECTURE: Two-Layer Search (Tantivy + Nucleo)
    // ════════════════════════════════════════════════════════════════════════════════
    //
    // 1. search(query) - Returns SearchResult with IDs + highlight ranges
    // 2. fetchByIds(ids) - Hydrates items from database
    //
    // ════════════════════════════════════════════════════════════════════════════════

    private func performSearch(query: String) async {
        guard let rustStore else {
            state = .error("Database not available")
            return
        }

        let signpostID = OSSignpostID(log: performanceLog)
        os_signpost(.begin, log: performanceLog, name: "search", signpostID: signpostID, "query=%{public}s", query)

        do {
            // Get search results (IDs + highlights) from Rust
            let searchResult = try await Task.detached {
                try rustStore.search(query: query)
            }.value

            guard !Task.isCancelled else { return }
            guard case .searching(let currentQuery, _) = state, currentQuery == query else { return }

            if searchResult.matches.isEmpty {
                state = .searching(query: query, state: .results([], hasMore: false))
                os_signpost(.end, log: performanceLog, name: "search", signpostID: signpostID, "count=0")
                return
            }

            // Extract IDs and fetch full items
            let ids = searchResult.matches.map { $0.itemId }
            let items = try await Task.detached {
                try rustStore.fetchByIds(ids: ids)
            }.value

            guard !Task.isCancelled else { return }
            guard case .searching(let currentQuery2, _) = state, currentQuery2 == query else { return }

            // Build ID -> highlights map
            var highlightsMap: [Int64: [HighlightRange]] = [:]
            for match in searchResult.matches {
                highlightsMap[match.itemId] = match.highlights
            }

            // Combine items with highlights, preserving search order
            var resultItems: [SearchResultItem] = []
            var itemsById: [Int64: ClipboardItem] = [:]
            for item in items {
                if let id = item.id {
                    itemsById[id] = item
                }
            }

            for match in searchResult.matches {
                if let item = itemsById[match.itemId] {
                    resultItems.append(SearchResultItem(
                        item: item,
                        highlights: highlightsMap[match.itemId] ?? []
                    ))
                }
            }

            state = .searching(query: query, state: .results(resultItems, hasMore: false))
            os_signpost(.end, log: performanceLog, name: "search", signpostID: signpostID, "total_hits=%d", searchResult.totalCount)
        } catch {
            guard !Task.isCancelled else { return }
            state = .error("Search failed: \(error.localizedDescription)")
            os_signpost(.end, log: performanceLog, name: "search", signpostID: signpostID, "error")
        }
    }

    // MARK: - Clipboard Monitoring

    func startMonitoring() {
        pollingTask?.cancel()
        setupSystemObservers()

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                // Skip polling entirely while system is sleeping
                if self.isSystemSleeping {
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

        sleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isSystemSleeping = true
            }
        }

        wakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isSystemSleeping = false
                // Brief burst of faster polling after wake to catch any changes
                self?.lastActivityTime = Date()
            }
        }
    }

    private func removeSystemObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        if let observer = sleepObserver {
            nc.removeObserver(observer)
            sleepObserver = nil
        }
        if let observer = wakeObserver {
            nc.removeObserver(observer)
            wakeObserver = nil
        }
    }

    /// Returns polling interval in milliseconds based on system state and activity
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
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount

        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        // User is actively copying - enable faster polling
        lastActivityTime = Date()

        // Skip concealed/sensitive content (e.g. passwords from 1Password, Bitwarden)
        let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        if pasteboard.data(forType: concealedType) != nil {
            return
        }

        // Check for image data first - get raw data only, defer compression
        let imageTypes: [NSPasteboard.PasteboardType] = [.tiff, .png]
        for type in imageTypes {
            if let rawData = pasteboard.data(forType: type) {
                saveImageItem(rawImageData: rawData)
                return
            }
        }

        // Otherwise check for text
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }

        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        let sourceAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // Move all DB operations to background
        guard let rustStore else { return }
        Task.detached { [weak self] in
            do {
                let newItemId = try rustStore.saveText(text: text, sourceApp: sourceApp, sourceAppBundleId: sourceAppBundleID)

                // If it's a URL, fetch metadata asynchronously
                if isUrl(text: text) {
                    await self?.fetchAndUpdateLinkMetadata(for: newItemId, url: text)
                }

                // Reload on main actor if browsing
                guard let self else { return }
                await MainActor.run { [weak self] in
                    if case .loaded = self?.state {
                        self?.loadItems(reset: true)
                    }
                }
            } catch {
                logError("Clipboard save failed: \(error)")
            }
        }
    }

    private func fetchAndUpdateLinkMetadata(for itemId: Int64, url: String) async {
        guard let rustStore else { return }

        let metadata = await LinkMetadataFetcher.shared.fetch(url: url)

        // Store in local vars for nonisolated access
        // If metadata is nil, we still need to update DB to mark as "failed" (empty title/image)
        let (title, imageData) = metadata?.databaseFields ?? ("", nil)

        // Database write needs to escape MainActor
        await Task.detached { [rustStore] in
            do {
                try rustStore.updateLinkMetadata(
                    itemId: itemId,
                    title: title,
                    imageData: imageData.map { Array($0) }
                )
            } catch {
                logError("Failed to update link metadata: \(error)")
            }
        }.value

        // Update the specific item in-place instead of reloading the entire list
        let newMetadataState = metadataStateFromDatabase(title: title, imageData: imageData)
        updateItemMetadata(itemId: itemId, url: url, metadataState: newMetadataState)
    }

    /// Reconstruct LinkMetadataState from database values
    private func metadataStateFromDatabase(title: String?, imageData: Data?) -> LinkMetadataState {
        switch (title, imageData) {
        case (nil, nil):
            return .pending
        case ("", nil):
            return .failed
        case (let title, let imageData):
            return .loaded(
                title: title?.isEmpty == true ? nil : title,
                imageData: imageData.map { Array($0) }
            )
        }
    }

    /// Updates a single item's metadata in-place without reloading the entire list
    private func updateItemMetadata(itemId: Int64, url: String, metadataState: LinkMetadataState) {
        switch state {
        case .loaded(let items, let hasMore):
            let updatedItems = items.map { item -> ClipboardItem in
                guard item.id == itemId else { return item }
                return ClipboardItem(
                    id: item.id,
                    content: .link(url: url, metadataState: metadataState),
                    contentHash: item.contentHash,
                    timestampUnix: item.timestampUnix,
                    sourceApp: item.sourceApp,
                    sourceAppBundleId: item.sourceAppBundleId
                )
            }
            state = .loaded(items: updatedItems, hasMore: hasMore)

        case .searching(let query, let searchState):
            let updateItems: ([SearchResultItem]) -> [SearchResultItem] = { items in
                items.map { resultItem -> SearchResultItem in
                    guard resultItem.item.id == itemId else { return resultItem }
                    let updatedItem = ClipboardItem(
                        id: resultItem.item.id,
                        content: .link(url: url, metadataState: metadataState),
                        contentHash: resultItem.item.contentHash,
                        timestampUnix: resultItem.item.timestampUnix,
                        sourceApp: resultItem.item.sourceApp,
                        sourceAppBundleId: resultItem.item.sourceAppBundleId
                    )
                    return SearchResultItem(item: updatedItem, highlights: resultItem.highlights)
                }
            }
            let newSearchState: SearchResultState
            switch searchState {
            case .loading(let previous):
                newSearchState = .loading(previousResults: updateItems(previous))
            case .results(let results, let hasMore):
                newSearchState = .results(updateItems(results), hasMore: hasMore)
            }
            state = .searching(query: query, state: newSearchState)

        default:
            break
        }
    }

    private func generateAndUpdateImageDescription(itemId: Int64, imageData: Data) async {
        guard let description = await ImageDescriptionGenerator.generateDescription(from: imageData) else { return }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let rustStore else { return }
        await Task.detached { [rustStore] in
            do {
                try rustStore.updateImageDescription(itemId: itemId, description: trimmed)
            } catch {
                logError("Failed to update image description: \(error)")
            }
        }.value

        await MainActor.run { [weak self] in
            self?.updateItemImageDescription(itemId: itemId, description: trimmed)
        }
    }

    private func updateItemImageDescription(itemId: Int64, description: String) {
        let updateItem: (ClipboardItem) -> ClipboardItem = { item in
            guard item.id == itemId else { return item }
            guard case .image(let data, let existingDescription) = item.content else { return item }
            guard existingDescription != description else { return item }
            return ClipboardItem(
                id: item.id,
                content: .image(data: data, description: description),
                contentHash: item.contentHash,
                timestampUnix: item.timestampUnix,
                sourceApp: item.sourceApp,
                sourceAppBundleId: item.sourceAppBundleId
            )
        }

        switch state {
        case .loaded(let items, let hasMore):
            state = .loaded(items: items.map(updateItem), hasMore: hasMore)

        case .searching(let query, let searchState):
            let updatedResults: ([SearchResultItem]) -> [SearchResultItem] = { items in
                items.map { resultItem in
                    SearchResultItem(item: updateItem(resultItem.item), highlights: resultItem.highlights)
                }
            }
            let newSearchState: SearchResultState
            switch searchState {
            case .loading(let previous):
                newSearchState = .loading(previousResults: updatedResults(previous))
            case .results(let results, let hasMore):
                newSearchState = .results(updatedResults(results), hasMore: hasMore)
            }
            state = .searching(query: query, state: newSearchState)

        default:
            break
        }
    }

    private func saveImageItem(rawImageData: Data) {
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        let sourceAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let maxPixels = Int(AppSettings.shared.maxImageMegapixels * 1_000_000)
        let quality = AppSettings.shared.imageCompressionQuality

        // Move compression and DB write to background
        guard let rustStore else { return }
        Task.detached { [weak self] in
            // Compress image with HEIC (HEVC)
            guard let compressedData = Self.compressToHEIC(rawImageData, quality: quality, maxPixels: maxPixels) else {
                logError("Image compression failed, skipping")
                return
            }

            do {
                let itemId = try rustStore.saveImage(
                    imageData: Array(compressedData),
                    sourceApp: sourceApp,
                    sourceAppBundleId: sourceAppBundleID
                )

                guard let self else { return }
                await MainActor.run { [weak self] in
                    if case .loaded = self?.state {
                        self?.loadItems(reset: true)
                    }
                }

                Task.detached { [weak self] in
                    await self?.generateAndUpdateImageDescription(itemId: itemId, imageData: compressedData)
                }
            } catch {
                logError("Image save failed: \(error)")
            }
        }
    }

    /// Compress image data to HEIC format using HEVC compression
    /// Resizes to maxPixels if larger, then compresses
    private nonisolated static func compressToHEIC(_ imageData: Data, quality: CGFloat, maxPixels: Int) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              var cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }

        // Resize if exceeds max pixels
        let width = cgImage.width
        let height = cgImage.height
        let pixels = width * height

        if pixels > maxPixels {
            let scale = sqrt(Double(maxPixels) / Double(pixels))
            let newWidth = Int(Double(width) * scale)
            let newHeight = Int(Double(height) * scale)

            guard let context = CGContext(
                data: nil,
                width: newWidth,
                height: newHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return nil
            }

            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

            guard let resized = context.makeImage() else {
                return nil
            }
            cgImage = resized
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            "public.heic" as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]

        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return data as Data
    }

    // MARK: - Actions

    func paste(item: ClipboardItem) {
        // Handle images differently - convert off main thread
        if case .image(let data, _) = item.content {
            pasteImage(data: Data(data), itemId: item.id)
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.textContent, forType: .string)
        lastChangeCount = pasteboard.changeCount

        if let id = item.id {
            Task {
                await updateItemTimestamp(id: id)
            }
        }
    }

    private func pasteImage(data: Data, itemId: Int64?) {
        // Pre-increment to avoid race with checkForChanges polling
        // The pasteboard changeCount will increment when we set data
        lastChangeCount = NSPasteboard.general.changeCount + 1

        Task {
            // Convert from stored format (HEIC) to TIFF off main thread
            let tiffData = await Task.detached {
                guard let image = NSImage(data: data),
                      let tiff = image.tiffRepresentation else {
                    return nil as Data?
                }
                return tiff
            }.value

            guard let tiffData else {
                // Conversion failed, reset the change count
                lastChangeCount = NSPasteboard.general.changeCount
                return
            }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(tiffData, forType: .tiff)
            lastChangeCount = pasteboard.changeCount

            if let itemId {
                await updateItemTimestamp(id: itemId)
            }
        }
    }

    private func updateItemTimestamp(id: Int64) async {
        guard let rustStore else { return }
        // Defer database operations to avoid blocking clipboard availability
        await Task.detached { [rustStore] in
            do {
                try rustStore.updateTimestamp(itemId: id)
            } catch {
                logError("Failed to update timestamp: \(error)")
            }
        }.value

        if case .loaded = state {
            loadItems(reset: true)
        }
    }

    func delete(item: ClipboardItem) {
        guard let id = item.id else { return }

        // Update UI immediately
        switch state {
        case .loaded(let items, let hasMore):
            state = .loaded(items: items.filter { $0.id != id }, hasMore: hasMore)
        case .searching(let query, let searchState):
            let newState: SearchResultState
            switch searchState {
            case .loading(let previous):
                newState = .loading(previousResults: previous.filter { $0.item.id != id })
            case .results(let results, let hasMore):
                newState = .results(results.filter { $0.item.id != id }, hasMore: hasMore)
            }
            state = .searching(query: query, state: newState)
        default:
            break
        }

        // Perform DB delete in background
        guard let rustStore else { return }
        Task.detached { [rustStore] in
            do {
                try rustStore.deleteItem(itemId: id)
            } catch {
                logError("Failed to delete: \(error)")
            }
        }
    }

    func clear() {
        // Update UI immediately
        state = .loaded(items: [], hasMore: false)

        // Perform expensive DB operations in background
        guard let rustStore else { return }
        Task.detached { [rustStore] in
            do {
                try rustStore.clearAll()
            } catch {
                logError("Failed to clear: \(error)")
            }
        }
    }

    // MARK: - Pruning

    func pruneIfNeeded() {
        let maxSizeGB = AppSettings.shared.maxDatabaseSizeGB
        guard maxSizeGB > 0, let rustStore else { return }

        let maxBytes = Int64(maxSizeGB * 1024 * 1024 * 1024)

        Task.detached { [rustStore] in
            do {
                _ = try rustStore.pruneToSize(maxBytes: maxBytes, keepRatio: 0.8)
            } catch {
                logError("Pruning failed: \(error)")
            }
        }
    }
}
