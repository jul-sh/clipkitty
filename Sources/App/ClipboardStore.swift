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

/// Display state - explicit variants for browse and search modes
enum DisplayState: Equatable {
    /// Initial loading state before any data
    case loading
    /// Browse mode - showing recent items (no search query)
    case browse([ItemMetadata])
    /// Search in progress - showing fallback items while waiting for results
    case searchLoading(query: String, fallbackItems: [ItemMetadata])
    /// Search complete - showing results
    case searchResults(query: String, results: [ItemMatch])
    /// Error state
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
    /// Current search query
    private var currentSearchQuery: String = ""

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

        // Capture fallback items from current state
        let fallback: [ItemMetadata] = {
            switch state {
            case .browse(let items):
                return items
            case .searchLoading(_, let fallbackItems):
                return fallbackItems
            case .searchResults(_, let results):
                return results.map { $0.itemMetadata }
            default:
                return []
            }
        }()

        state = .searchLoading(query: query, fallbackItems: fallback)

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            await performSearch(query: query)
        }
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


    /// Fetch full ClipboardItem by ID with optional search highlighting
    func fetchItem(id: Int64, searchQuery: String? = nil) async -> ClipboardItem? {
        guard let rustStore else { return nil }
        return try? await Task.detached {
            let items = try rustStore.fetchByIds(ids: [id], searchQuery: searchQuery)
            return items.first
        }.value
    }

    // MARK: - Loading

    /// Load items for browse mode (search with empty query)
    private func loadItems(reset: Bool) {
        // Extract current items to preserve during refresh (avoid flash)
        let currentItems: [ItemMetadata] = {
            if case .browse(let items) = state {
                return items
            }
            return []
        }()

        // Only show loading spinner if we have no cached items
        if reset && currentItems.isEmpty {
            state = .loading
        }

        guard let rustStore else { return }
        let signpostID = OSSignpostID(log: performanceLog)
        os_signpost(.begin, log: performanceLog, name: "loadItems", signpostID: signpostID)

        Task.detached {
            do {
                // Browse mode: search with empty query, extract just metadata
                let result = try rustStore.search(query: "")
                let metadata = result.matches.map { $0.itemMetadata }

                await MainActor.run { [weak self] in
                    os_signpost(.end, log: performanceLog, name: "loadItems", signpostID: signpostID)
                    self?.state = .browse(metadata)
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
    // SEARCH ARCHITECTURE: Single-pass search with Rust-computed highlights
    // ════════════════════════════════════════════════════════════════════════════════
    //
    // search(query) - Returns SearchResult with ItemMatch objects containing:
    //   - itemMetadata: Item ID, icon, preview, source app, timestamp
    //   - matchData: Match text with highlights, line number
    //
    // All highlight computation happens in Rust, never in Swift.
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
            // Get search results with all match data from Rust
            let searchResult = try await Task.detached {
                try rustStore.search(query: query)
            }.value

            guard !Task.isCancelled else { return }
            guard case .searchLoading(let currentQuery, _) = state, currentQuery == query else { return }

            state = .searchResults(query: query, results: searchResult.matches)
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
                // Rust handles URL detection and metadata fetching automatically
                _ = try rustStore.saveText(text: text, sourceApp: sourceApp, sourceAppBundleId: sourceAppBundleID)

                // Reload on main actor if in browse mode
                guard let self else { return }
                await MainActor.run { [weak self] in
                    if case .browse = self?.state {
                        self?.loadItems(reset: true)
                    }
                }
            } catch {
                logError("Clipboard save failed: \(error)")
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
                logError("Failed to update image description: \(error)")
            }
        }.value

        await MainActor.run { [weak self] in
            if case .browse = self?.state {
                self?.loadItems(reset: true)
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
            // Compress image with HEIC (HEVC)
            guard let compressedData = Self.compressToHEIC(rawImageData, quality: quality, maxPixels: maxPixels) else {
                logError("Image compression failed, skipping")
                return
            }

            do {
                let itemId = try rustStore.saveImage(
                    imageData: compressedData,
                    sourceApp: sourceApp,
                    sourceAppBundleId: sourceAppBundleID
                )

                guard let self else { return }
                await MainActor.run { [weak self] in
                    if case .browse = self?.state {
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
            pasteImage(data: Data(data), itemId: item.itemMetadata.itemId)
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.textContent, forType: .string)
        lastChangeCount = pasteboard.changeCount

        let id = item.itemMetadata.itemId
        Task {
            await updateItemTimestamp(id: id)
        }
    }

    func paste(itemId: Int64, content: ClipboardContent) {
        // Handle images differently - convert off main thread
        if case .image(let data, _) = content {
            pasteImage(data: Data(data), itemId: itemId)
            return
        }

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

        // Reload if in browse mode
        if case .browse = state {
            loadItems(reset: true)
        }
    }

    func delete(itemId: Int64) {
        // Update UI immediately
        switch state {
        case .browse(let items):
            state = .browse(items.filter { $0.itemId != itemId })
        case .searchLoading(let query, let fallback):
            state = .searchLoading(
                query: query,
                fallbackItems: fallback.filter { $0.itemId != itemId }
            )
        case .searchResults(let query, let results):
            state = .searchResults(
                query: query,
                results: results.filter { $0.itemMetadata.itemId != itemId }
            )
        default:
            break
        }

        // Perform DB delete in background
        guard let rustStore else { return }
        Task.detached { [rustStore] in
            do {
                try rustStore.deleteItem(itemId: itemId)
            } catch {
                logError("Failed to delete: \(error)")
            }
        }
    }

    func delete(item: ClipboardItem) {
        delete(itemId: item.itemMetadata.itemId)
    }

    func clear() {
        // Update UI immediately
        state = .browse([])

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
