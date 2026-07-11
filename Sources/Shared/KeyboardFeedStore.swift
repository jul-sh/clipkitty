import Foundation

/// File-based hand-off of recent clips from the main app to the keyboard
/// extension — the same pattern as `PendingShareQueue`, in the opposite
/// direction: plain files in the App Group container, no database access from
/// the extension process.
///
/// The main app rewrites the snapshot whenever history changes (foreground
/// ingest, sync, suspension); the keyboard only ever reads it. Reads and
/// writes race harmlessly because the snapshot is a single atomically-written
/// file. The keyboard also drops a "last opened" marker here so the app's
/// activation flow can tell that the keyboard is enabled and has full access
/// (without full access the keyboard cannot reach the App Group container at
/// all, so the marker's existence proves the whole chain works).
public enum KeyboardFeedStore {
    private static let keyboardDirName = "keyboard"
    private static let snapshotFilename = "snapshot.json"
    private static let markerFilename = "last-opened.json"

    /// Bumped when the snapshot format changes; readers ignore snapshots
    /// written with a different version rather than misparse them.
    public static let schemaVersion = 1

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
        public let generatedAtUnix: Int64
        public let items: [Item]

        public init(version: Int, generatedAtUnix: Int64, items: [Item]) {
            self.version = version
            self.generatedAtUnix = generatedAtUnix
            self.items = items
        }
    }

    // MARK: - Write (main app)

    /// `baseDirectory` overrides the App Group location; tests use it to stay
    /// hermetic (the simulator hands every test the same shared container).
    public static func write(items: [Item], now: Date = Date(), in baseDirectory: URL? = nil) throws {
        let dir = try ensureDirectory(baseDirectory)
        let snapshot = Snapshot(
            version: schemaVersion,
            generatedAtUnix: Int64(now.timeIntervalSince1970),
            items: Array(items.prefix(maxItems))
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: dir.appendingPathComponent(snapshotFilename), options: .atomic)
    }

    // MARK: - Read (keyboard extension)

    public static func loadSnapshot(in baseDirectory: URL? = nil) -> Snapshot? {
        guard let dir = directory(baseDirectory),
              let data = try? Data(contentsOf: dir.appendingPathComponent(snapshotFilename)),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == schemaVersion
        else {
            return nil
        }
        return snapshot
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
        try? data.write(to: dir.appendingPathComponent(markerFilename), options: .atomic)
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
}
