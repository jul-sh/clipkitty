import Foundation

// MARK: - ClipKitty Error Types

/// Errors that can occur during clipboard operations
enum ClipboardError: LocalizedError {
    case databaseInitFailed(underlying: Error)
    case databaseOperationFailed(operation: String, underlying: Error)
    case imageCompressionFailed
    case pasteboardAccessFailed
    case fileAccessFailed(path: String)
    case linkMetadataFetchFailed(url: String)

    var errorDescription: String? {
        switch self {
        case .databaseInitFailed:
            return String(localized: "Failed to initialize clipboard database")
        case let .databaseOperationFailed(operation, _):
            return String(localized: "Database operation failed: \(operation)")
        case .imageCompressionFailed:
            return String(localized: "Failed to compress image")
        case .pasteboardAccessFailed:
            return String(localized: "Failed to access clipboard")
        case let .fileAccessFailed(path):
            return String(localized: "Failed to access file: \(path)")
        case let .linkMetadataFetchFailed(url):
            return String(localized: "Failed to fetch link preview: \(url)")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .databaseInitFailed:
            return String(localized: "Try restarting ClipKitty. If the problem persists, check disk space.")
        case .databaseOperationFailed:
            return String(localized: "The operation will be retried automatically.")
        case .imageCompressionFailed:
            return String(localized: "The image may be too large or in an unsupported format.")
        case .pasteboardAccessFailed:
            return String(localized: "Another application may be using the clipboard.")
        case .fileAccessFailed:
            return String(localized: "Check that the file exists and you have permission to access it.")
        case .linkMetadataFetchFailed:
            return String(localized: "The website may be unavailable or blocking previews.")
        }
    }
}
