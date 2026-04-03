import Foundation

/// Centralised database-path resolution for all processes (main app, intents, share extension).
///
/// Prefers the App Group container so extensions can share the database.
/// Falls back to Application Support when the App Group is unavailable
/// (e.g. unit tests running without entitlements).
public enum DatabasePath {
    public static let appGroupId = "group.com.eviljuliette.clipkitty"
    private static let appDirName = "ClipKitty"
    private static let dbFilename = "clipboard.db"

    // MARK: - Resolve

    /// Returns the path to `clipboard.db`, creating intermediate directories if needed.
    public static func resolve() throws -> String {
        let dir = try databaseDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(dbFilename).path
    }

    // MARK: - Migration

    /// Copies the database from the legacy Application Support location to the
    /// App Group container. Idempotent — no-op if already migrated, if there is
    /// no legacy data, or if the App Group is unavailable.
    public static func migrateIfNeeded() {
        guard let groupDir = appGroupDirectory() else { return }
        let targetDir = groupDir.appendingPathComponent(appDirName, isDirectory: true)
        let targetDB = targetDir.appendingPathComponent(dbFilename)

        // Already migrated or extension created data first — leave it alone.
        if FileManager.default.fileExists(atPath: targetDB.path) { return }

        guard let legacyDir = legacyDirectory() else { return }
        let legacyDB = legacyDir.appendingPathComponent(dbFilename)
        guard FileManager.default.fileExists(atPath: legacyDB.path) else { return }

        do {
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            // Copy the main database file and any WAL/SHM companions.
            for suffix in ["", "-shm", "-wal"] {
                let src = legacyDir.appendingPathComponent(dbFilename + suffix)
                let dst = targetDir.appendingPathComponent(dbFilename + suffix)
                if FileManager.default.fileExists(atPath: src.path) {
                    try FileManager.default.copyItem(at: src, to: dst)
                }
            }
        } catch {
            // Migration is best-effort. The main app will create a fresh database
            // in the App Group container if this fails.
            print("[DatabasePath] Migration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Internal

    private static func databaseDirectory() throws -> URL {
        if let groupDir = appGroupDirectory() {
            return groupDir.appendingPathComponent(appDirName, isDirectory: true)
        }
        // Fallback for environments without App Group entitlement (tests, Simulator).
        return try legacyDirectoryOrThrow()
    }

    private static func appGroupDirectory() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    private static func legacyDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .map { $0.appendingPathComponent(appDirName, isDirectory: true) }
    }

    private static func legacyDirectoryOrThrow() throws -> URL {
        guard let dir = legacyDirectory() else {
            preconditionFailure("Application Support directory unavailable — the OS sandbox is misconfigured")
        }
        return dir
    }
}
