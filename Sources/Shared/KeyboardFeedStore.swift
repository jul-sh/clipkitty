import Darwin
import Foundation

/// File-based hand-off of recent clips from the main app to the keyboard
/// extension — the same pattern as `PendingShareQueue`, in the opposite
/// direction: plain files in the App Group container, no database access from
/// the extension process.
///
/// App-side mutation surfaces rewrite the snapshot whenever history changes;
/// the keyboard only ever reads it. Publishers are serialized by a file lock,
/// stale candidates are rejected by generation, and readers see a single
/// atomically-written file. The keyboard also drops a "last opened" marker
/// so the app's
/// activation flow can tell that the keyboard is enabled and has full access
/// (without full access the keyboard cannot reach the App Group container at
/// all, so the marker's existence proves the whole chain works).
public enum KeyboardFeedStore {
    private static let keyboardDirName = "keyboard"
    private static let snapshotFilename = "snapshot.json"
    private static let lockFilename = "snapshot.lock"
    private static let generationFilename = "snapshot-generation"
    private static let markerFilename = "last-opened.json"

    /// Cross-process invalidations. Files remain the source of truth; these
    /// notifications only tell a live reader to re-read them.
    public enum Change: Sendable {
        case feed
        case activation

        fileprivate var notificationName: CFNotificationName {
            let value = switch self {
            case .feed: "com.eviljuliette.clipkitty.keyboard.feed-changed"
            case .activation: "com.eviljuliette.clipkitty.keyboard.activation-changed"
            }
            return CFNotificationName(value as CFString)
        }
    }

    /// Bumped when the snapshot format changes; readers ignore snapshots
    /// written with a different version rather than misparse them.
    public static let schemaVersion = 2

    /// The snapshot covers the newest clips only — the keyboard is a quick
    /// picker, not a browser. 30 cards is more scrolling than anyone does on
    /// a keyboard while staying a trivially small file.
    public static let maxItems = 30

    /// Items whose insertable text exceeds this are left out of the feed:
    /// inserting megabytes through `UITextDocumentProxy` beachballs the host
    /// app, and a card excerpt can't meaningfully represent them anyway.
    public static let maxInsertableTextLength = 200_000

    // MARK: - Model

    public struct Item: Codable, Equatable, Identifiable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case text
            case link
            case color
        }

        public let id: String
        public let kind: Kind
        /// The full text a tap inserts: the text body, the URL string, or the
        /// color's textual value.
        public let text: String
        public let sourceApp: String?
        public let timestampUnix: Int64
        /// Packed RGBA for color clips so the keyboard can render the swatch
        /// without parsing the color text.
        public let colorRGBA: UInt32?

        public init(
            id: String,
            kind: Kind,
            text: String,
            sourceApp: String?,
            timestampUnix: Int64,
            colorRGBA: UInt32? = nil
        ) {
            self.id = id
            self.kind = kind
            self.text = text
            self.sourceApp = sourceApp
            self.timestampUnix = timestampUnix
            self.colorRGBA = colorRGBA
        }
    }

    public struct Snapshot: Codable, Equatable, Sendable {
        public let version: Int
        /// Monotonically orders publishers across processes.
        public let generation: UInt64
        public let items: [Item]

        public init(version: Int, generation: UInt64, items: [Item]) {
            self.version = version
            self.generation = generation
            self.items = items
        }
    }

    /// Historical evidence written by the keyboard extension. The containing
    /// app combines this with the current enabled-input-mode list at its UIKit
    /// boundary; a previous open must never stand in for current enablement.
    public enum ActivationHistory: Equatable, Sendable {
        case neverOpened
        case opened(lastOpened: Date)
    }

    // MARK: - Write (main app)

    /// `baseDirectory` overrides the App Group location; tests use it to stay
    /// hermetic (the simulator hands every test the same shared container).
    public static func write(items: [Item], in baseDirectory: URL? = nil) throws {
        let generation = try reserveGeneration(in: baseDirectory)
        try write(items: items, generation: generation, in: baseDirectory)
    }

    /// Reserve an ordered publisher generation before reading the database.
    /// Gaps are harmless when a process exits before publishing.
    public static func reserveGeneration(in baseDirectory: URL? = nil) throws -> UInt64 {
        let dir = try ensureDirectory(baseDirectory)
        return try withSnapshotLock(in: dir) {
            let generationURL = dir.appendingPathComponent(generationFilename)
            let reserved = (try? String(contentsOf: generationURL, encoding: .utf8))
                .flatMap(UInt64.init) ?? 0
            let snapshotGeneration = loadSnapshotFile(in: dir)?.generation ?? 0
            let current = max(reserved, snapshotGeneration)
            guard current < UInt64.max else { throw POSIXError(.EOVERFLOW) }
            let next = current + 1
            try Data(String(next).utf8).write(to: generationURL, options: .atomic)
            return next
        }
    }

    public static func write(
        items: [Item],
        generation: UInt64,
        in baseDirectory: URL? = nil
    ) throws {
        let dir = try ensureDirectory(baseDirectory)
        let snapshot = Snapshot(
            version: schemaVersion,
            generation: generation,
            items: Array(items.prefix(maxItems))
        )
        let data = try JSONEncoder().encode(snapshot)
        let snapshotURL = dir.appendingPathComponent(snapshotFilename)
        let didWrite = try withSnapshotLock(in: dir) {
            if let current = loadSnapshotFile(in: dir),
               current.generation >= snapshot.generation
            {
                return false
            }
            try data.write(to: snapshotURL, options: .atomic)
            return true
        }
        if didWrite {
            post(.feed)
        }
    }

    // MARK: - Read (keyboard extension)

    public static func loadSnapshot(in baseDirectory: URL? = nil) -> Snapshot? {
        guard let dir = directory(baseDirectory) else { return nil }
        return loadSnapshotFile(in: dir)
    }

    // MARK: - Activation marker

    private struct Marker: Codable {
        let lastOpenedUnix: Int64
    }

    /// Called by the keyboard whenever it comes on screen. Succeeding requires
    /// both that the keyboard is enabled and that full access is granted, so
    /// the app treats the marker as proof of a completed setup.
    public static func recordKeyboardOpened(now: Date = Date(), in baseDirectory: URL? = nil) {
        guard let dir = try? ensureDirectory(baseDirectory) else { return }
        let marker = Marker(lastOpenedUnix: Int64(now.timeIntervalSince1970))
        guard let data = try? JSONEncoder().encode(marker) else { return }
        do {
            try data.write(to: dir.appendingPathComponent(markerFilename), options: .atomic)
            post(.activation)
        } catch {
            return
        }
    }

    /// When the keyboard last came on screen, or nil if it never has (or full
    /// access has never been granted).
    public static func keyboardLastOpened(in baseDirectory: URL? = nil) -> Date? {
        guard let dir = directory(baseDirectory),
              let data = try? Data(contentsOf: dir.appendingPathComponent(markerFilename)),
              let marker = try? JSONDecoder().decode(Marker.self, from: data)
        else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(marker.lastOpenedUnix))
    }

    public static func activationHistory(in baseDirectory: URL? = nil) -> ActivationHistory {
        switch keyboardLastOpened(in: baseDirectory) {
        case let .some(lastOpened): .opened(lastOpened: lastOpened)
        case .none: .neverOpened
        }
    }

    /// An async sequence of cross-process invalidations for the selected
    /// file. Consumers must re-read the store on every element; notifications
    /// deliberately carry no state and may be coalesced by the OS.
    public static func changes(for change: Change) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let observation = ChangeObservation(change: change) {
                continuation.yield()
            }
            continuation.onTermination = { _ in
                withExtendedLifetime(observation) {}
            }
        }
    }

    // MARK: - Private

    private static func directory(_ baseDirectory: URL?) -> URL? {
        let groupDir: URL
        if let baseDirectory {
            groupDir = baseDirectory
        } else if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DatabasePath.appGroupId
        ) {
            groupDir = container
        } else {
            return nil
        }
        return groupDir
            .appendingPathComponent("ClipKitty", isDirectory: true)
            .appendingPathComponent(keyboardDirName, isDirectory: true)
    }

    private static func ensureDirectory(_ baseDirectory: URL?) throws -> URL {
        guard let dir = directory(baseDirectory) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "App Group container unavailable",
            ])
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func loadSnapshotFile(in directory: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(snapshotFilename)),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == schemaVersion
        else {
            return nil
        }
        return snapshot
    }

    private static func withSnapshotLock<T>(in directory: URL, body: () throws -> T) throws -> T {
        let lockURL = directory.appendingPathComponent(lockFilename)
        let descriptor = lockURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw POSIXError(.EIO)
        }
        defer { Darwin.close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(.EIO)
        }
        defer { flock(descriptor, LOCK_UN) }

        return try body()
    }

    private static func post(_ change: Change) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            change.notificationName,
            nil,
            nil,
            true
        )
    }
}

private final class ChangeObservation: @unchecked Sendable {
    private let change: KeyboardFeedStore.Change
    private let handler: @Sendable () -> Void

    init(change: KeyboardFeedStore.Change, handler: @escaping @Sendable () -> Void) {
        self.change = change
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            keyboardFeedStoreChangeCallback,
            change.notificationName.rawValue,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            change.notificationName,
            nil
        )
    }

    func receive() {
        handler()
    }
}

private func keyboardFeedStoreChangeCallback(
    _: CFNotificationCenter?,
    observer: UnsafeMutableRawPointer?,
    _: CFNotificationName?,
    _: UnsafeRawPointer?,
    _: CFDictionary?
) {
    guard let observer else { return }
    Unmanaged<ChangeObservation>.fromOpaque(observer).takeUnretainedValue().receive()
}
