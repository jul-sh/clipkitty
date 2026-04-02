import Foundation
import os

// MARK: - ClipKitty Error Types

/// Errors that can occur during clipboard operations
public enum ClipboardError: LocalizedError {
    case databaseInitFailed(underlying: Error)
    case databaseOperationFailed(operation: String, underlying: Error)
    case imageCompressionFailed
    case pasteboardAccessFailed
    case fileAccessFailed(path: String)
    case linkMetadataFetchFailed(url: String)

    public var errorDescription: String? {
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

    public var recoverySuggestion: String? {
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

// MARK: - Result Type Extensions

extension Result where Failure == Error {
    /// Log failure and return nil, or return success value
    @discardableResult
    public func logFailure(
        _ logger: Logger,
        operation: String,
        file: String = #file,
        function _: String = #function,
        line: Int = #line
    ) -> Success? {
        switch self {
        case let .success(value):
            return value
        case let .failure(error):
            logger.error("[\(operation)] \(error.localizedDescription) at \(file):\(line)")
            return nil
        }
    }
}

// MARK: - Error Notification Integration

/// Centralized error reporting that shows user-facing notifications for critical errors
@MainActor
public enum ErrorReporter {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ClipKitty", category: "Error")

    /// Callback for showing notification snackbars. Set by FloatingPanelController on init.
    public static var showNotification: ((NotificationKind) -> Void)?

    /// Report an error, optionally showing a notification to the user
    public static func report(
        _ error: Error,
        showToast: Bool = false,
        file: String = #file,
        function _: String = #function,
        line: Int = #line
    ) {
        // Always log
        let fileName = (file as NSString).lastPathComponent
        logger.error("[\(fileName):\(line)] \(error.localizedDescription)")

        // Optionally show notification for user-facing errors
        if showToast {
            let message: String
            if let clipboardError = error as? ClipboardError {
                message = clipboardError.errorDescription ?? "An error occurred"
            } else {
                message = error.localizedDescription
            }
            showNotification?(.passive(message: message, iconSystemName: "exclamationmark.triangle.fill"))
        }
    }

    /// Report a critical error that should always be shown to the user
    public static func reportCritical(_ error: Error) {
        report(error, showToast: true)
    }

    /// Log a warning (less severe than error)
    public static func warn(
        _ message: String,
        file: String = #file,
        line: Int = #line
    ) {
        let fileName = (file as NSString).lastPathComponent
        logger.warning("[\(fileName):\(line)] \(message)")
    }
}

// MARK: - Async Operation Wrapper

/// Execute an async operation with error handling
public func withErrorHandling<T>(
    operation: String,
    showToast: Bool = false,
    body: () async throws -> T
) async -> T? {
    do {
        return try await body()
    } catch {
        await ErrorReporter.report(
            ClipboardError.databaseOperationFailed(operation: operation, underlying: error),
            showToast: showToast
        )
        return nil
    }
}

/// Execute a throwing operation with error handling, returning Result
public func withResult<T>(
    operation: String,
    body: () throws -> T
) -> Result<T, ClipboardError> {
    do {
        return try .success(body())
    } catch {
        return .failure(.databaseOperationFailed(operation: operation, underlying: error))
    }
}
