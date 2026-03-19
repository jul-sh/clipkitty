import AppKit
import ClipKittyRust
import Foundation
import ImageIO
import Observation
import os
import QuartzCore
import UniformTypeIdentifiers

// MARK: - Logging

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ClipKitty", category: "ClipboardStore")
private let maxAnimatedFrames = 50
private let maxAnimatedDuration: Double = 3.0

private final class MissingRepositorySearchOperation: ClipboardSearchOperation {
    func cancel() {}

    func awaitOutcome() async -> RepositorySearchOutcome {
        .failure(.databaseOperationFailed(
            operation: "search",
            underlying: NSError(
                domain: "ClipKitty",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Database not available"]
            )
        ))
    }
}

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
        case let .results(query, _, _), let .resultsLoading(query, _):
            return query
        case .loading, .error:
            return ""
        }
    }

    /// Current browser filter for refreshes driven by this store facade.
    private(set) var queryFilter: ItemQueryFilter = .all

    // MARK: - Private State

    /// Rust-backed repository facade
    private var repository: ClipboardRepository?

    private enum SearchExecution {
        case idle
        case debouncing(query: String, task: Task<Void, Never>)
        case running(query: String, operation: ClipboardSearchOperation, observer: Task<Void, Never>)

        mutating func cancel() {
            switch self {
            case .idle:
                break
            case let .debouncing(_, task):
                task.cancel()
            case let .running(_, operation, observer):
                operation.cancel()
                observer.cancel()
            }
            self = .idle
        }
    }

    private var searchExecution: SearchExecution = .idle
    /// Current search query
    private var currentSearchQuery: String = ""

    /// Increments each time the display is reset - views observe this to reset local state
    /// Uses Int which will overflow after ~2 billion increments, but this is acceptable
    /// as the counter only needs to detect changes, not maintain absolute ordering
    private(set) var displayVersion: Int = 0

    /// Pasteboard for clipboard operations (injected for testability)
    private let pasteboard: PasteboardProtocol
    private let pasteService: PasteService
    private let workspace: WorkspaceProtocol
    private let fileManager: FileManagerProtocol
    private var previewLoader: PreviewLoader?
    @ObservationIgnored private var pasteboardMonitor: PasteboardMonitor!

    // MARK: - Initialization

    private let isScreenshotMode: Bool

    init(
        screenshotMode: Bool = false,
        pasteboard: PasteboardProtocol = NSPasteboard.general,
        workspace: WorkspaceProtocol = NSWorkspace.shared,
        fileManager: FileManagerProtocol = FileManager.default
    ) {
        isScreenshotMode = screenshotMode
        self.pasteboard = pasteboard
        pasteService = PasteService(pasteboard: pasteboard)
        self.workspace = workspace
        self.fileManager = fileManager
        pasteboardMonitor = PasteboardMonitor(
            pasteboard: pasteboard,
            workspace: workspace
        ) { [weak self] detectedContent in
            self?.handleDetectedPasteboardContent(detectedContent)
        }
        setupDatabase()
        refresh()
        pruneIfNeeded()
    }

    /// Current database size in bytes (cached, updated async)
    private(set) var databaseSizeBytes: Int64 = 0

    /// Refresh database size asynchronously
    func refreshDatabaseSize() {
        guard let repository else { return }
        Task {
            let result = await repository.databaseSize()
            if case let .success(size) = result {
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
            guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                let error = ClipboardError.databaseInitFailed(underlying: NSError(domain: "ClipKitty", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to locate application support directory"]))
                ErrorReporter.reportCritical(error)
                state = .error(error.localizedDescription)
                return
            }
            let appDir = appSupport.appendingPathComponent("ClipKitty", isDirectory: true)
            try fileManager.createDirectory(at: appDir, withIntermediateDirectories: true, attributes: nil)

            let dbPath = appDir.appendingPathComponent(Self.databaseFilename(screenshotMode: isScreenshotMode)).path

            let store = try ClipKittyRust.ClipboardStore(dbPath: dbPath)
            let repository = ClipboardRepository(store: store)
            self.repository = repository
            previewLoader = PreviewLoader(repository: repository)
        } catch {
            let dbError = ClipboardError.databaseInitFailed(underlying: error)
            ErrorReporter.reportCritical(dbError)
            state = .error(dbError.localizedDescription)
        }
    }

    // MARK: - Public API

    func setSearchQuery(_ newQuery: String) {
        let query = newQuery

        searchExecution.cancel()
        currentSearchQuery = query

        // Capture fallback results from current state (preserves match text to prevent flash)
        let fallback: [ItemMatch] = {
            switch state {
            case let .results(_, items, _), let .resultsLoading(_, items):
                return items
            case .loading, .error:
                return []
            }
        }()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        state = .resultsLoading(query: query, fallback: fallback)
        CATransaction.commit()

        if query.isEmpty {
            beginSearch(query: query)
            return
        }

        let debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.beginSearch(query: query)
            }
        }
        searchExecution = .debouncing(query: query, task: debounceTask)
    }

    func resetForDisplay() {
        searchExecution.cancel()
        queryFilter = .all
        displayVersion += 1
        refresh()
    }

    func setQueryFilter(_ filter: ItemQueryFilter) {
        queryFilter = filter
        refresh()
    }

    func startSearch(query: String, filter: ItemQueryFilter) -> ClipboardSearchOperation {
        guard let repository else {
            return MissingRepositorySearchOperation()
        }
        return repository.startSearch(query: query, filter: filter)
    }

    func search(query: String, filter: ItemQueryFilter) async throws -> SearchResult {
        switch await startSearch(query: query, filter: filter).awaitOutcome() {
        case let .success(searchResult):
            return searchResult
        case .cancelled:
            throw ClipboardError.databaseOperationFailed(
                operation: "search",
                underlying: ClipKittyError.Cancelled
            )
        case let .failure(error):
            throw error
        }
    }

    /// Fetch full ClipboardItem by ID
    func fetchItem(id: Int64) async -> ClipboardItem? {
        guard let previewLoader else { return nil }
        return await previewLoader.fetchItem(id: id)
    }

    func loadRowDecorations(itemIds: [Int64], query: String) async -> [RowDecorationResult] {
        guard let repository else { return [] }
        return await repository.computeRowDecorations(itemIds: itemIds, query: query)
    }

    func loadPreviewPayload(itemId: Int64, query: String) async -> PreviewPayload? {
        guard let repository else { return nil }
        return await repository.loadPreviewPayload(itemId: itemId, query: query)
    }

    /// Fetch link metadata using LinkPresentation and persist to database
    /// Returns the updated item if successful
    func fetchLinkMetadata(url: String, itemId: Int64) async -> ClipboardItem? {
        guard let previewLoader else { return nil }
        return await previewLoader.refreshLinkMetadata(url: url, itemId: itemId)
    }

    // MARK: - Refresh

    /// Refresh items with current query (convenience for reload scenarios)
    private func refresh() {
        setSearchQuery(currentSearchQuery)
    }

    private func beginSearch(query: String) {
        guard let repository else {
            state = .error(String(localized: "Database not available"))
            return
        }

        let operation = repository.startSearch(query: query, filter: queryFilter)
        let observer = Task { [weak self] in
            let outcome = await operation.awaitOutcome()
            await MainActor.run {
                self?.applySearchOutcome(outcome, query: query)
            }
        }
        searchExecution = .running(query: query, operation: operation, observer: observer)
    }

    private func applySearchOutcome(_ outcome: RepositorySearchOutcome, query: String) {
        guard case let .resultsLoading(currentQuery, _) = state, currentQuery == query else { return }

        switch outcome {
        case let .success(searchResult):
            let oldState = state
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            state = .results(
                query: query,
                items: searchResult.matches,
                firstItem: searchResult.firstPreviewPayload?.item
            )
            CATransaction.commit()

            Task.detached(priority: .background) {
                _ = oldState
            }
        case .cancelled:
            break
        case let .failure(error):
            ErrorReporter.report(error, showToast: false)
            state = .error(error.localizedDescription)
        }

        if case let .running(runningQuery, _, _) = searchExecution, runningQuery == query {
            searchExecution = .idle
        }
    }

    // MARK: - Clipboard Monitoring

    func startMonitoring() {
        pasteboardMonitor.start()
    }

    func stopMonitoring() {
        pasteboardMonitor.stop()
    }

    private func handleDetectedPasteboardContent(_ detectedContent: DetectedPasteboardContent) {
        switch detectedContent {
        case let .text(text, sourceApp, sourceAppBundleId):
            saveTextItem(text: text, sourceApp: sourceApp, sourceAppBundleId: sourceAppBundleId)
        case let .image(data, isAnimated, sourceApp, sourceAppBundleId):
            saveImageItem(
                rawImageData: data,
                isAnimated: isAnimated,
                sourceApp: sourceApp,
                sourceAppBundleID: sourceAppBundleId
            )
        case let .files(urls, sourceApp, sourceAppBundleId):
            saveFileItems(urls: urls, sourceApp: sourceApp, sourceAppBundleID: sourceAppBundleId)
        }
    }

    private func saveTextItem(text: String, sourceApp: String?, sourceAppBundleId: String?) {
        guard let repository else { return }

        Task {
            let result = await repository.saveText(text: text, sourceApp: sourceApp, sourceAppBundleId: sourceAppBundleId)

            switch result {
            case let .success(itemId):
                if self.hasResults {
                    self.refresh()
                }

                if itemId > 0, URL(string: text) != nil, text.hasPrefix("http") {
                    guard AppSettings.shared.generateLinkPreviews else { return }
                    _ = await self.fetchLinkMetadata(url: text, itemId: itemId)
                    if self.hasResults {
                        self.refresh()
                    }
                }

            case let .failure(error):
                ErrorReporter.report(error, showToast: false)
            }
        }
    }

    private func generateAndUpdateImageDescription(itemId: Int64, imageData: Data) async {
        guard let description = await ImageDescriptionGenerator.generateDescription(from: imageData) else { return }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let repository else { return }
        let result = await repository.updateImageDescription(itemId: itemId, description: trimmed)

        if case let .failure(error) = result {
            ErrorReporter.report(error, showToast: false)
        }

        if hasResults {
            refresh()
        }
    }

    /// Save text that was edited in the preview pane.
    /// Update a text item's content in-place.
    func updateTextItem(itemId: Int64, text: String) async -> Result<Void, ClipboardError> {
        guard let repository else {
            return .failure(.databaseOperationFailed(
                operation: "updateTextItem",
                underlying: NSError(domain: "ClipKitty", code: 1, userInfo: [NSLocalizedDescriptionKey: "Repository not initialized"])
            ))
        }

        return await repository.updateTextItem(itemId: itemId, text: text)
    }

    private func saveImageItem(
        rawImageData: Data,
        isAnimated: Bool,
        sourceApp: String? = nil,
        sourceAppBundleID: String? = nil
    ) {
        let sourceApp = sourceApp ?? workspace.frontmostApplication?.localizedName
        let sourceAppBundleID = sourceAppBundleID ?? workspace.frontmostApplication?.bundleIdentifier
        let maxPixels = Int(AppSettings.shared.maxImageMegapixels * 1_000_000)
        let quality = AppSettings.shared.imageCompressionQuality

        guard let repository else { return }
        Task {
            guard let processedImage = await ImageIngestService.process(
                rawImageData: rawImageData,
                isAnimated: isAnimated,
                quality: quality,
                maxPixels: maxPixels,
                thumbnailGenerator: { imageData in Self.generateThumbnail(imageData) },
                heicCompressor: { data, quality, maxPixels in
                    Self.compressToHEIC(data, quality: quality, maxPixels: maxPixels)
                },
                animatedHeicCompressor: { data, quality, maxPixels in
                    Self.compressToAnimatedHEIC(data, quality: quality, maxPixels: maxPixels)
                }
            ) else {
                ErrorReporter.report(ClipboardError.imageCompressionFailed, showToast: false)
                return
            }

            // Save to database
            let result = await repository.saveImage(
                imageData: processedImage.compressedData,
                thumbnail: processedImage.thumbnailData,
                sourceApp: sourceApp,
                sourceAppBundleId: sourceAppBundleID,
                isAnimated: processedImage.isAnimated
            )

            switch result {
            case let .success(itemId):
                if self.hasResults {
                    self.refresh()
                }

                // Generate image description in background
                Task {
                    await self.generateAndUpdateImageDescription(itemId: itemId, imageData: processedImage.compressedData)
                }

            case let .failure(error):
                ErrorReporter.report(error, showToast: false)
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

    /// Compress animated GIF to animated HEIC with frame reduction and duration cap
    /// Returns (heicData, isAnimated) - isAnimated is false if GIF had only 1 frame
    private nonisolated static func compressToAnimatedHEIC(_ gifData: Data, quality: CGFloat, maxPixels: Int) -> (Data, Bool)? {
        guard let imageSource = CGImageSourceCreateWithData(gifData as CFData, nil) else { return nil }

        let frameCount = CGImageSourceGetCount(imageSource)

        // Single frame - just compress as static HEIC
        if frameCount <= 1 {
            guard let staticData = compressToHEIC(gifData, quality: quality, maxPixels: maxPixels) else { return nil }
            return (staticData, false)
        }

        // Calculate total duration and frame delays
        var frameDelays: [Double] = []
        for i in 0 ..< frameCount {
            let delay = gifFrameDelay(source: imageSource, index: i)
            frameDelays.append(delay)
        }
        let totalDuration = frameDelays.reduce(0, +)

        // Determine which frames to keep based on caps
        let framesToKeep: [Int]
        let adjustedDelays: [Double]

        if totalDuration > maxAnimatedDuration || frameCount > maxAnimatedFrames {
            // Need to reduce frames - sample evenly
            let targetFrameCount = min(maxAnimatedFrames, Int(Double(frameCount) * (maxAnimatedDuration / totalDuration)))
            let actualTargetCount = max(2, targetFrameCount) // Keep at least 2 frames for animation

            var indices: [Int] = []
            let step = Double(frameCount - 1) / Double(actualTargetCount - 1)
            for i in 0 ..< actualTargetCount {
                indices.append(min(Int(Double(i) * step), frameCount - 1))
            }
            framesToKeep = indices

            // Adjust delays proportionally to maintain visual timing
            let durationScale = min(1.0, maxAnimatedDuration / totalDuration)
            adjustedDelays = framesToKeep.map { frameDelays[$0] * durationScale }
        } else {
            framesToKeep = Array(0 ..< frameCount)
            adjustedDelays = frameDelays
        }

        // Create animated HEIC
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            "public.heics" as CFString, // HEIC sequence format
            framesToKeep.count,
            nil
        ) else { return nil }

        // Get first frame to determine scaling
        guard let firstCGImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return nil }
        let pixels = firstCGImage.width * firstCGImage.height
        let needsResize = pixels > maxPixels
        let scale = needsResize ? sqrt(Double(maxPixels) / Double(pixels)) : 1.0
        let targetW = needsResize ? max(1, Int(Double(firstCGImage.width) * scale)) : firstCGImage.width
        let targetH = needsResize ? max(1, Int(Double(firstCGImage.height) * scale)) : firstCGImage.height

        for (idx, frameIndex) in framesToKeep.enumerated() {
            // Check for task cancellation to allow early termination of expensive frame processing
            guard !Task.isCancelled else { return nil }

            guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, frameIndex, nil) else { continue }

            let finalImage: CGImage
            if needsResize {
                guard let resized = resizeCGImage(cgImage, maxWidth: targetW, maxHeight: targetH) else { continue }
                finalImage = resized
            } else {
                finalImage = cgImage
            }

            let frameProperties: [CFString: Any] = [
                kCGImagePropertyHEICSLoopCount: 0, // Loop forever
                kCGImagePropertyHEICSDelayTime: adjustedDelays[idx],
            ]

            CGImageDestinationAddImage(destination, finalImage, [
                kCGImageDestinationLossyCompressionQuality: quality,
                kCGImagePropertyHEICSDictionary: frameProperties,
            ] as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else { return nil }
        return (data as Data, true)
    }

    /// Extract frame delay from GIF properties (default 0.1s if not specified)
    private nonisolated static func gifFrameDelay(source: CGImageSource, index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gifProps = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else {
            return 0.1
        }

        // Try unclamped delay first, then clamped
        if let delay = gifProps[kCGImagePropertyGIFUnclampedDelayTime] as? Double, delay > 0 {
            return delay
        }
        if let delay = gifProps[kCGImagePropertyGIFDelayTime] as? Double, delay > 0 {
            return delay
        }
        return 0.1
    }

    /// Generate a small JPEG thumbnail (max 64x64) for list display
    private nonisolated static func generateThumbnail(_ imageData: Data, maxSize: Int = 64) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return nil }

        guard let resized = resizeCGImage(cgImage, maxWidth: maxSize, maxHeight: maxSize, quality: .medium) else { return nil }
        return encodeCGImage(resized, type: "public.jpeg" as CFString, quality: 0.6)
    }

    // MARK: - File Items

    private func saveFileItems(
        urls: [URL],
        sourceApp: String? = nil,
        sourceAppBundleID: String? = nil
    ) {
        let sourceApp = sourceApp ?? workspace.frontmostApplication?.localizedName
        let sourceAppBundleID = sourceAppBundleID ?? workspace.frontmostApplication?.bundleIdentifier

        guard let repository else { return }
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

            let result = await repository.saveFiles(
                paths: paths,
                filenames: filenames,
                fileSizes: fileSizes,
                utis: utis,
                bookmarkDataList: bookmarkDataList,
                thumbnail: nil,
                sourceApp: sourceApp,
                sourceAppBundleId: sourceAppBundleID
            )

            switch result {
            case .success:
                if self.hasResults {
                    self.refresh()
                }
            case let .failure(error):
                ErrorReporter.report(error, showToast: false)
            }
        }
    }

    // MARK: - Actions

    func paste(itemId: Int64, content: ClipboardContent) {
        // Handle images differently - convert off main thread
        if case let .image(data, _, isAnimated) = content {
            pasteImage(data: Data(data), isAnimated: isAnimated, itemId: itemId)
            return
        }

        if case let .file(_, files) = content {
            pasteFiles(files: files, itemId: itemId)
            return
        }

        pasteboardMonitor.acknowledgeLocalWrite(changeCount: pasteService.writeText(content.textContent))

        Task { [weak self] in
            await self?.updateItemTimestamp(id: itemId)
        }
    }

    private func pasteImage(data: Data, isAnimated: Bool, itemId: Int64?) {
        Task {
            if isAnimated {
                // Convert animated HEIC to GIF for pasting (CPU-intensive, use background)
                let gifData: Data? = await withCheckedContinuation { continuation in
                    Task.detached(priority: .userInitiated) {
                        continuation.resume(returning: Self.convertAnimatedHEICToGIF(data))
                    }
                }

                guard let gifData else {
                    self.pasteboardMonitor.acknowledgeLocalWrite(changeCount: self.pasteboard.changeCount)
                    return
                }

                let fallback = NSImage(data: data)?.tiffRepresentation
                self.pasteboardMonitor.acknowledgeLocalWrite(
                    changeCount: self.pasteService.writeAnimatedImage(gifData: gifData, tiffFallback: fallback)
                )
            } else {
                // Convert from stored format (HEIC) to TIFF off main thread
                let tiffData: Data? = await withCheckedContinuation { continuation in
                    Task.detached(priority: .userInitiated) {
                        guard let image = NSImage(data: data),
                              let tiff = image.tiffRepresentation
                        else {
                            continuation.resume(returning: nil)
                            return
                        }
                        continuation.resume(returning: tiff)
                    }
                }

                guard let tiffData else {
                    self.pasteboardMonitor.acknowledgeLocalWrite(changeCount: self.pasteboard.changeCount)
                    return
                }

                self.pasteboardMonitor.acknowledgeLocalWrite(changeCount: self.pasteService.writeStaticImage(tiffData))
            }

            if let itemId {
                await self.updateItemTimestamp(id: itemId)
            }
        }
    }

    /// Convert animated HEIC (HEICS) to GIF format
    private nonisolated static func convertAnimatedHEICToGIF(_ heicData: Data) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(heicData as CFData, nil) else { return nil }

        let frameCount = CGImageSourceGetCount(imageSource)
        guard frameCount > 1 else { return nil }

        let gifData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            gifData as CFMutableData,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else { return nil }

        // Set GIF properties for looping
        let gifProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0, // Loop forever
            ],
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

        // Copy each frame with its delay
        for i in 0 ..< frameCount {
            guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, i, nil) else { continue }

            // Get frame delay from HEICS properties
            var delay = 0.1
            if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, i, nil) as? [CFString: Any],
               let heicsProps = properties[kCGImagePropertyHEICSDictionary] as? [CFString: Any],
               let frameDelay = heicsProps[kCGImagePropertyHEICSDelayTime] as? Double
            {
                delay = frameDelay
            }

            let frameProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                ],
            ]
            CGImageDestinationAddImage(destination, cgImage, frameProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else { return nil }
        return gifData as Data
    }

    private func pasteFiles(files: [FileEntry], itemId: Int64) {
        // Resolve each file's bookmark to get current URL
        var resolvedURLs: [URL] = []
        for file in files {
            // Use stored path directly (no bookmark data in sandboxed mode)
            resolvedURLs.append(URL(fileURLWithPath: file.path))
        }

        guard !resolvedURLs.isEmpty else { return }

        // Write to pasteboard with both modern and legacy types for broad compatibility.
        // Finder requires NSFilenamesPboardType for file paste; other apps use public.file-url.
        pasteboardMonitor.acknowledgeLocalWrite(changeCount: pasteService.writeFiles(resolvedURLs))

        Task { [weak self] in
            await self?.updateItemTimestamp(id: itemId)
        }
    }

    private func updateItemTimestamp(id: Int64) async {
        guard let repository else { return }
        let result = await repository.updateTimestamp(itemId: id)

        // Log any errors but don't show toast (timestamp update is non-critical)
        if case let .failure(error) = result {
            ErrorReporter.report(error, showToast: false)
        }

        // Reload if in browse mode
        if hasResults {
            refresh()
        }
    }

    func delete(itemId: Int64) {
        // Update UI immediately
        switch state {
        case let .results(query, items, firstItem):
            let filteredItems = items.filter { $0.itemMetadata.itemId != itemId }
            let newFirstItem = firstItem?.itemMetadata.itemId == itemId ? nil : firstItem
            state = .results(query: query, items: filteredItems, firstItem: newFirstItem)
        case let .resultsLoading(query, fallback):
            state = .resultsLoading(
                query: query,
                fallback: fallback.filter { $0.itemMetadata.itemId != itemId }
            )
        case .loading, .error:
            break
        }

        guard let repository else { return }
        Task {
            if case let .failure(error) = await repository.delete(itemId: itemId) {
                ErrorReporter.report(error, showToast: true)
            }
        }
    }

    func deleteItem(itemId: Int64) async -> Result<Void, ClipboardError> {
        guard let repository else {
            return .failure(.databaseOperationFailed(
                operation: "deleteItem",
                underlying: NSError(domain: "ClipKitty", code: 1, userInfo: [NSLocalizedDescriptionKey: "Database not available"])
            ))
        }
        return await repository.delete(itemId: itemId)
    }

    func addTag(itemId: Int64, tag: ItemTag) async -> Result<Void, ClipboardError> {
        guard let repository else {
            return .failure(.databaseOperationFailed(
                operation: "addTag",
                underlying: NSError(domain: "ClipKitty", code: 1, userInfo: [NSLocalizedDescriptionKey: "Database not available"])
            ))
        }
        return await repository.addTag(itemId: itemId, tag: tag)
    }

    func removeTag(itemId: Int64, tag: ItemTag) async -> Result<Void, ClipboardError> {
        guard let repository else {
            return .failure(.databaseOperationFailed(
                operation: "removeTag",
                underlying: NSError(domain: "ClipKitty", code: 1, userInfo: [NSLocalizedDescriptionKey: "Database not available"])
            ))
        }
        return await repository.removeTag(itemId: itemId, tag: tag)
    }

    func clear() {
        // Update UI immediately
        state = .results(query: "", items: [], firstItem: nil)

        guard let repository else { return }
        Task {
            if case let .failure(error) = await repository.clear() {
                ErrorReporter.report(error, showToast: true)
            }
        }
    }

    func clearAll() async -> Result<Void, ClipboardError> {
        guard let repository else {
            return .failure(.databaseOperationFailed(
                operation: "clear",
                underlying: NSError(domain: "ClipKitty", code: 1, userInfo: [NSLocalizedDescriptionKey: "Database not available"])
            ))
        }
        return await repository.clear()
    }

    // MARK: - Pruning

    func pruneIfNeeded() {
        let maxSizeGB = AppSettings.shared.maxDatabaseSizeGB
        guard maxSizeGB > 0, let repository else { return }

        let maxBytes = Int64(maxSizeGB * 1024 * 1024 * 1024)

        Task {
            if case let .failure(error) = await repository.pruneToSize(maxBytes: maxBytes, keepRatio: 0.8) {
                ErrorReporter.report(error, showToast: false)
            }
        }
    }
}
