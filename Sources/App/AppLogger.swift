import Foundation
import Observation

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let message: String

    enum LogLevel: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }
}

@MainActor
@Observable
final class AppLogger {
    static let shared = AppLogger()

    private(set) var entries: [LogEntry] = []
    private let maxEntries = 500

    private init() {}

    func info(_ message: String) {
        append(level: .info, message: message)
    }

    func warning(_ message: String) {
        append(level: .warning, message: message)
    }

    func error(_ message: String) {
        append(level: .error, message: message)
        #if DEBUG
        print("[ERROR] \(message)")
        #endif
    }

    func clear() {
        entries.removeAll()
    }

    private func append(level: LogEntry.LogLevel, message: String) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        entries.append(entry)

        // Trim old entries if needed
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }
}

// Helper for logging from nonisolated/background contexts
func logError(_ message: String) {
    Task { @MainActor in
        AppLogger.shared.error(message)
    }
}

func logWarning(_ message: String) {
    Task { @MainActor in
        AppLogger.shared.warning(message)
    }
}

func logInfo(_ message: String) {
    Task { @MainActor in
        AppLogger.shared.info(message)
    }
}
