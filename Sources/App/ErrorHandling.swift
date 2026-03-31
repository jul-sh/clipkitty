import Foundation
import os

// MARK: - Result Type Extensions

extension Result where Failure == Error {
    /// Log failure and return nil, or return success value
    @discardableResult
    func logFailure(
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
enum ErrorReporter {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ClipKitty", category: "Error")

    /// Callback for showing notification snackbars. Set by FloatingPanelController on init.
    static var showNotification: ((NotificationKind) -> Void)?

    /// Report an error, optionally showing a notification to the user
    static func report(
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
    static func reportCritical(_ error: Error) {
        report(error, showToast: true)
    }

    /// Log a warning (less severe than error)
    static func warn(
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
func withErrorHandling<T>(
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
func withResult<T>(
    operation: String,
    body: () throws -> T
) -> Result<T, ClipboardError> {
    do {
        return try .success(body())
    } catch {
        return .failure(.databaseOperationFailed(operation: operation, underlying: error))
    }
}
