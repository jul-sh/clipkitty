#if !SANDBOXED
import Foundation
import ClipKittyRust

/// Monitors files for moves, renames, and deletions using DispatchSource.
/// Uses file system object sources on parent directories to detect changes.
/// Resolves bookmarks when files disappear to determine if moved, trashed, or missing.
@MainActor
final class FileWatcher {
    private var sources: [String: DispatchSourceFileSystemObject] = [:] // keyed by dir path
    private var fileDescriptors: [String: Int32] = [:] // keyed by dir path, for cleanup
    private var watchedFiles: [String: (fileItemId: Int64, filename: String, bookmarkData: Data)] = [:] // keyed by file path
    private var watchOrder: [String] = [] // tracks insertion order for eviction
    private let maxWatched = 50

    /// Callback fired when a watched file changes status (moved, trashed, missing)
    var onFileChanged: ((Int64, FileStatus) -> Void)?

    func watch(path: String, fileItemId: Int64, filename: String, bookmarkData: Data) {
        // Evict oldest if at capacity
        if watchedFiles.count >= maxWatched, let oldest = watchOrder.first {
            unwatchFile(oldest)
        }

        watchedFiles[path] = (fileItemId: fileItemId, filename: filename, bookmarkData: bookmarkData)
        watchOrder.append(path)

        // Watch the parent directory
        let dirPath = (path as NSString).deletingLastPathComponent
        guard sources[dirPath] == nil else { return }

        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }

        fileDescriptors[dirPath] = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.handleDirectoryEvent(dirPath: dirPath)
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        sources[dirPath] = source
    }

    func stopAll() {
        for (_, source) in sources {
            source.cancel()
        }
        sources.removeAll()
        fileDescriptors.removeAll()
        watchedFiles.removeAll()
        watchOrder.removeAll()
    }

    private func unwatchFile(_ path: String) {
        watchedFiles.removeValue(forKey: path)
        watchOrder.removeAll { $0 == path }

        // Clean up directory source if no more files in that directory
        let dirPath = (path as NSString).deletingLastPathComponent
        let hasFilesInDir = watchedFiles.keys.contains { ($0 as NSString).deletingLastPathComponent == dirPath }
        if !hasFilesInDir, let source = sources.removeValue(forKey: dirPath) {
            source.cancel()
            fileDescriptors.removeValue(forKey: dirPath)
        }
    }

    private func handleDirectoryEvent(dirPath: String) {
        // Check all watched files in this directory
        let filesInDir = watchedFiles.filter { ($0.key as NSString).deletingLastPathComponent == dirPath }

        for (filePath, entry) in filesInDir {
            if !FileManager.default.fileExists(atPath: filePath) {
                // File disappeared — resolve bookmark to determine actual status
                let status = resolveFileStatus(bookmarkData: entry.bookmarkData)
                onFileChanged?(entry.fileItemId, status)
                unwatchFile(filePath)
            }
        }
    }

    /// Resolve a bookmark to determine the file's current status
    private func resolveFileStatus(bookmarkData: Data) -> FileStatus {
        var isStale = false
        guard let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return .missing
        }

        let resolvedPath = resolvedURL.path
        if resolvedPath.contains("/.Trash/") {
            return .trashed
        }
        return .moved(newPath: resolvedPath)
    }
}
#endif
