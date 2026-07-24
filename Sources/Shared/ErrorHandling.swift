import Foundation
import os

// MARK: - ClipKitty Error Types

/// Errors that can occur during clipboard operations
public enum ClipboardError: LocalizedError {
    case databaseInitFailed(underlying: Error)
    case databaseOperationFailed(operation: String, underlying: Error)
    case imageCompressionFailed

    public var errorDescription: String? {
        switch self {
        case .databaseInitFailed:
            return String(localized: "Failed to initialize clipboard database")
        case let .databaseOperationFailed(operation, _):
            return String(localized: "Database operation failed: \(operation)")
        case .imageCompressionFailed:
            return String(localized: "Failed to compress image")
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
        }
    }
}

// MARK: - Error Notification Integration

/// Centralized error reporting that shows user-facing notifications for critical errors
@MainActor
public enum ErrorReporter {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ClipKitty", category: "Error")

    /// Callback for showing notification snackbars. Set by FloatingPanelController on init.
    public static var showNotification: ((NotificationRequest) -> Void)?

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
}
