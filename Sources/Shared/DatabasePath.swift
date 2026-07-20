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
        let dbPath = dir.appendingPathComponent(dbFilename).path
        // Harden the on-disk store: iOS data protection + backup exclusion.
        // Best-effort; a failure here must never break path resolution.
        applyDataProtection(toDirectory: dir)
        excludeFromBackup(directory: dir)
        return dbPath
    }

    // MARK: - Hardening

    /// Applies file data protection to the database directory and its clip-bearing
    /// contents so the plaintext store is unreadable while the device is locked.
    ///
    /// Uses `.completeUnlessOpen`: files stay accessible to an already-open handle
    /// across a device lock (the app keeps its SQLite handle open in the
    /// background), but a file created or opened while locked is inaccessible.
    /// `.complete` would break background database access, so it is deliberately
    /// not used here. Directory protection makes newly-created files inherit the
    /// class. iOS-only; macOS has no data-protection API and this file compiles
    /// for both platforms.
    private static func applyDataProtection(toDirectory dir: URL) {
        #if os(iOS)
            let fm = FileManager.default
            let protection: [FileAttributeKey: Any] = [
                .protectionKey: FileProtectionType.completeUnlessOpen,
            ]
            // The directory itself, so newly-created files inherit protection.
            var paths = [dir.path]
            // The database file and its WAL/SHM companions.
            for suffix in ["", "-wal", "-shm"] {
                paths.append(dir.appendingPathComponent(dbFilename + suffix).path)
            }
            // Any tantivy index directory sitting alongside the database.
            if let entries = try? fm.contentsOfDirectory(atPath: dir.path) {
                for entry in entries where entry.hasPrefix("tantivy_index_v") {
                    paths.append(dir.appendingPathComponent(entry).path)
                }
            }
            for path in paths where fm.fileExists(atPath: path) {
                // Best-effort: log nothing sensitive, never crash.
                try? fm.setAttributes(protection, ofItemAtPath: path)
            }
        #endif
    }

    /// Excludes the database directory (and everything inside it: the database,
    /// WAL/SHM companions, and the search index) from device backups. Secrets
    /// must not sweep into unencrypted local iTunes/Finder backups; CloudKit sync
    /// is the intended cross-device migration path. Best-effort; a failure here
    /// must never break path resolution. iOS-only for clarity; the flag is a
    /// no-op on macOS.
    private static func excludeFromBackup(directory dir: URL) {
        #if os(iOS)
            var url = dir
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            // Best-effort: never crash if the flag cannot be set.
            try? url.setResourceValues(values)
        #endif
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
