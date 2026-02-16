import Foundation
import AppKit
import Observation
import ClipKittyRust

import ImageIO

#if !SANDBOXED
import QuickLookThumbnailing
#endif

// MARK: - Performance Tracing



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
    private var lastActivityTime: Date = Date()
    private var isSystemSleeping: Bool = false
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var searchTask: Task<Void, Never>?
    /// Current search query
    private var currentSearchQuery: String = ""

    /// Increments each time the display is reset - views observe this to reset local state
    private(set) var displayVersion: Int = 0

    /// Link metadata fetcher using LinkPresentation framework
    private let linkMetadataFetcher = LinkMetadataFetcher()

    #if !SANDBOXED
    /// File watcher for move/delete tracking
    private let fileWatcher = FileWatcher()
    #endif

    // MARK: - Initialization

    private let isScreenshotMode: Bool

    init(screenshotMode: Bool = false) {
        self.isScreenshotMode = screenshotMode
        lastChangeCount = NSPasteboard.general.changeCount
        setupDatabase()
        #if !SANDBOXED
        setupFileWatcher()
        #endif
        refresh()
        pruneIfNeeded()
    }

    #if !SANDBOXED
    private func setupFileWatcher() {
        fileWatcher.onFileChanged = { [weak self] itemId, status in
            guard let self else { return }
            try? self.updateFileStatusViaRust(
                itemId: itemId,
                status: status.toDatabaseStr(),
                newPath: status.movedPath
            )
            self.refresh()
        }
    }
    #endif


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
        let query = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)

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

        state = .resultsLoading(query: query, fallback: fallback)

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
        return try? await Task.detached {
            let items = try rustStore.fetchByIds(itemIds: [id])
            return items.first
        }.value
    }

    /// Fetch link metadata using LinkPresentation and persist to database
    /// Returns the updated item if successful
    func fetchLinkMetadata(url: String, itemId: Int64) async -> ClipboardItem? {
        guard let rustStore else { return nil }

        // Fetch metadata using LinkPresentation framework
        guard let metadata = await linkMetadataFetcher.fetchMetadata(for: url, itemId: itemId) else {
            // Mark as failed
            await Task.detached { [rustStore] in
                try? rustStore.updateLinkMetadata(
                    itemId: itemId,
                    title: "",
                    description: nil,
                    imageData: nil
                )
            }.value
            return await fetchItem(id: itemId)
        }

        // Persist to database
        let imageData = metadata.imageData
        Task.detached { [rustStore] in
            try? rustStore.updateLinkMetadata(
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
            state = .error("Database not available")
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
            guard case .resultsLoading(let currentQuery, _) = state, currentQuery == query else { return }

            state = .results(query: query, items: searchResult.matches, firstItem: searchResult.firstItem)
        } catch ClipKittyError.Cancelled {
        } catch {
            guard !Task.isCancelled else { return }
            state = .error("Search failed: \(error.localizedDescription)")
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
        #if !SANDBOXED
        fileWatcher.stopAll()
        #endif
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

        // Check for file URLs first (file copies also put .tiff and .string on the pasteboard)
        #if !SANDBOXED
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !fileURLs.isEmpty {
            return
        }
        #endif

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
                // Rust handles URL detection and metadata fetching automatically
                let itemId = try rustStore.saveText(text: text, sourceApp: sourceApp, sourceAppBundleId: sourceAppBundleID)

                // Reload on main actor if in browse mode
                guard let self else { return }
                await MainActor.run { [weak self] in
                    if self?.hasResults == true {
                        self?.refresh()
                    }
                }

                // If this is a new item (not duplicate) and looks like a URL, prefetch link metadata
                if itemId > 0, URL(string: text) != nil, text.hasPrefix("http") {
                    Task.detached { [weak self] in
                        _ = await self?.fetchLinkMetadata(url: text, itemId: itemId)
                    }
                }
            } catch {
            }
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
            }
        }.value

        await MainActor.run { [weak self] in
            if self?.hasResults == true {
                self?.refresh()
            }
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
            // Generate thumbnail from original image (before HEIC compression)
            // HEIC is not supported by Rust's image crate, so we generate in Swift
            let thumbnail = Self.generateThumbnail(rawImageData)

            // Compress image with HEIC (HEVC)
            guard let compressedData = Self.compressToHEIC(rawImageData, quality: quality, maxPixels: maxPixels) else {
                return
            }

            do {
                let itemId = try rustStore.saveImage(
                    imageData: compressedData,
                    thumbnail: thumbnail,
                    sourceApp: sourceApp,
                    sourceAppBundleId: sourceAppBundleID
                )

                guard let self else { return }
                await MainActor.run { [weak self] in
                    if self?.hasResults == true {
                        self?.refresh()
                    }
                }

                Task.detached { [weak self] in
                    await self?.generateAndUpdateImageDescription(itemId: itemId, imageData: compressedData)
                }
            } catch {
            }
        }
    }

    /// Resize a CGImage to fit within maxWidth x maxHeight, preserving aspect ratio.
    private nonisolated static func resizeCGImage(_ cgImage: CGImage, maxWidth: Int, maxHeight: Int, quality: CGInterpolationQuality = .high) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > maxWidth || height > maxHeight else { return cgImage }

        let scale = min(Double(maxWidth) / Double(width), Double(maxHeight) / Double(height))
        let newWidth = max(1, Int(Double(width) * scale))
        let newHeight = max(1, Int(Double(height) * scale))

        guard let context = CGContext(
            data: nil, width: newWidth, height: newHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = quality
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }

    /// Encode a CGImage to a specific format with the given quality.
    private nonisolated static func encodeCGImage(_ cgImage: CGImage, type: CFString, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Compress image data to HEIC format, resizing to maxPixels if larger
    private nonisolated static func compressToHEIC(_ imageData: Data, quality: CGFloat, maxPixels: Int) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return nil }

        let pixels = cgImage.width * cgImage.height
        let image: CGImage
        if pixels > maxPixels {
            let scale = sqrt(Double(maxPixels) / Double(pixels))
            let targetW = max(1, Int(Double(cgImage.width) * scale))
            let targetH = max(1, Int(Double(cgImage.height) * scale))
            guard let resized = resizeCGImage(cgImage, maxWidth: targetW, maxHeight: targetH) else { return nil }
            image = resized
        } else {
            image = cgImage
        }
        return encodeCGImage(image, type: "public.heic" as CFString, quality: quality)
    }

    /// Generate a small JPEG thumbnail (max 64x64) for list display
    private nonisolated static func generateThumbnail(_ imageData: Data, maxSize: Int = 64) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return nil }

        guard let resized = resizeCGImage(cgImage, maxWidth: maxSize, maxHeight: maxSize, quality: .medium) else { return nil }
        return encodeCGImage(resized, type: "public.jpeg" as CFString, quality: 0.6)
    }

    // MARK: - File Items

    #if !SANDBOXED
    private func saveFileItems(urls: [URL]) {
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        let sourceAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        guard let rustStore else { return }
        Task.detached { [weak self] in
            for url in urls {
                guard url.isFileURL else { continue }

                let path = url.path
                let filename = url.lastPathComponent

                // Get file size and UTI
                let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .typeIdentifierKey])
                let fileSize = UInt64(resourceValues?.fileSize ?? 0)
                let uti = resourceValues?.typeIdentifier ?? "public.item"

                // Create bookmark for move tracking
                guard let bookmarkData = try? url.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: [.nameKey, .pathKey],
                    relativeTo: nil
                ) else { continue }

                // Generate QuickLook thumbnail
                let thumbnail = await Self.generateQuickLookThumbnail(for: url)

                do {
                    let itemId = try rustStore.saveFile(
                        path: path,
                        filename: filename,
                        fileSize: fileSize,
                        uti: uti,
                        bookmarkData: bookmarkData,
                        thumbnail: thumbnail,
                        sourceApp: sourceApp,
                        sourceAppBundleId: sourceAppBundleID
                    )

                    guard let self else { return }
                    await MainActor.run { [weak self] in
                        if self?.hasResults == true {
                            self?.refresh()
                        }
                    }

                    // Start watching the file for moves/deletes
                    if itemId > 0 {
                        await MainActor.run { [weak self] in
                            self?.fileWatcher.watch(path: path, itemId: itemId, filename: filename, bookmarkData: bookmarkData)
                        }
                    }
                } catch {
                }
            }
        }
    }

    private nonisolated static func generateQuickLookThumbnail(for url: URL) async -> Data? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 128, height: 128),
            scale: 2.0,
            representationTypes: .thumbnail
        )
        guard let thumbnail = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request) else { return nil }
        return encodeCGImage(thumbnail.cgImage, type: "public.jpeg" as CFString, quality: 0.7)
    }
    #endif

    // MARK: - Actions

    func paste(itemId: Int64, content: ClipboardContent) {
        // Handle images differently - convert off main thread
        if case .image(let data, _) = content {
            pasteImage(data: Data(data), itemId: itemId)
            return
        }

        #if !SANDBOXED
        if case .file(let path, _, _, _, let bookmarkData, _) = content {
            pasteFile(path: path, bookmarkData: Data(bookmarkData), itemId: itemId)
            return
        }
        #endif

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content.textContent, forType: .string)
        lastChangeCount = pasteboard.changeCount

        Task {
            await updateItemTimestamp(id: itemId)
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

    #if !SANDBOXED
    private func pasteFile(path: String, bookmarkData: Data, itemId: Int64) {
        // Pre-increment to avoid race with checkForChanges polling
        lastChangeCount = NSPasteboard.general.changeCount + 1

        // Try to resolve bookmark first (handles moved files), fall back to original path
        var isStale = false
        let resolvedURL: URL
        if let url = try? URL(resolvingBookmarkData: bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
            resolvedURL = url
        } else {
            resolvedURL = URL(fileURLWithPath: path)
        }

        // Write to pasteboard with both modern and legacy types for broad compatibility.
        // Finder requires NSFilenamesPboardType for file paste; other apps use public.file-url.
        // Uses the type-based API (declareTypes) which increments changeCount once.
        let pasteboard = NSPasteboard.general
        let filenameType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        pasteboard.declareTypes([filenameType, .fileURL, .string], owner: nil)
        pasteboard.setPropertyList([resolvedURL.path], forType: filenameType)
        pasteboard.setString(resolvedURL.absoluteString, forType: .fileURL)
        pasteboard.setString(resolvedURL.path, forType: .string)
        lastChangeCount = pasteboard.changeCount

        Task {
            await updateItemTimestamp(id: itemId)
        }
    }
    #endif

    private func updateItemTimestamp(id: Int64) async {
        guard let rustStore else { return }
        // Defer database operations to avoid blocking clipboard availability
        await Task.detached { [rustStore] in
            do {
                try rustStore.updateTimestamp(itemId: id)
            } catch {
            }
        }.value

        // Reload if in browse mode
        if hasResults {
            refresh()
        }
    }

    func delete(itemId: Int64) {
        // Update UI immediately
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

        // Perform DB delete in background
        guard let rustStore else { return }
        Task.detached { [rustStore] in
            do {
                try rustStore.deleteItem(itemId: itemId)
            } catch {
            }
        }
    }

    func clear() {
        // Update UI immediately
        state = .results(query: "", items: [], firstItem: nil)

        // Perform expensive DB operations in background
        guard let rustStore else { return }
        Task.detached { [rustStore] in
            do {
                try rustStore.clear()
            } catch {
            }
        }
    }

    // MARK: - File Status Update

    #if !SANDBOXED
    func updateFileStatusViaRust(itemId: Int64, status: String, newPath: String?) throws {
        guard let rustStore else { return }
        try rustStore.updateFileStatus(itemId: itemId, status: status, newPath: newPath)
    }
    #endif

    // MARK: - Pruning

    func pruneIfNeeded() {
        let maxSizeGB = AppSettings.shared.maxDatabaseSizeGB
        guard maxSizeGB > 0, let rustStore else { return }

        let maxBytes = Int64(maxSizeGB * 1024 * 1024 * 1024)

        Task.detached { [rustStore] in
            do {
                _ = try rustStore.pruneToSize(maxBytes: maxBytes, keepRatio: 0.8)
            } catch {
            }
        }
    }
}
