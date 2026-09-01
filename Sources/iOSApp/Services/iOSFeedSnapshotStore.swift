import ClipKittyCore
import ClipKittyRust
import ClipKittyStore
import Foundation

/// The last default-feed search response, persisted so a warm-booted session
/// can render the previous UI state instantly while the store reopens.
struct iOSFeedSnapshot {
    let items: [ItemMatch]
    let totalCount: Int
}

/// Durable storage for the warm-boot feed snapshot.
///
/// The payload reuses the generated uniffi converters for `ItemMatch`, so the
/// on-disk rows are byte-identical to what the last live search produced and
/// no parallel serializable model exists. That wire format is not stable
/// across releases, so the header pins the exact app version and any mismatch
/// or decode failure is treated as an absent snapshot.
enum iOSFeedSnapshotStore {
    static let maxItems = 60
    private static let magic = Array("CKFS".utf8)
    private static let formatVersion: UInt32 = 1

    static func load() -> iOSFeedSnapshot? {
        guard let url = fileURL(),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return decode(data)
    }

    /// Persists off the caller's actor. The snapshot is a pure cache: a write
    /// lost to process death is recreated by the next live search, and a
    /// torn write fails closed at decode because writes are atomic.
    static func scheduleSave(items: [ItemMatch], totalCount: Int) {
        let capped = Array(items.prefix(maxItems))
        Task.detached(priority: .utility) {
            guard let url = fileURL() else { return }
            let data = encode(items: capped, totalCount: totalCount)
            try? data.write(
                to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        }
    }

    /// Clearing history must also clear the snapshot so a wiped store can
    /// never flash its old contents on the next launch.
    static func scheduleClear() {
        Task.detached(priority: .utility) {
            guard let url = fileURL() else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func fileURL() -> URL? {
        guard let databasePath = try? DatabasePath.resolve() else { return nil }
        return URL(fileURLWithPath: databasePath)
            .deletingLastPathComponent()
            .appendingPathComponent("feed-snapshot.bin")
    }

    private static var appVersionStamp: [UInt8] {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return Array("\(short)/\(build)".utf8)
    }

    static func encode(items: [ItemMatch], totalCount: Int) -> Data {
        var buf = [UInt8]()
        buf.append(contentsOf: magic)
        appendUInt32(formatVersion, to: &buf)
        let version = appVersionStamp
        appendUInt32(UInt32(version.count), to: &buf)
        buf.append(contentsOf: version)
        appendUInt32(UInt32(clamping: totalCount), to: &buf)
        appendUInt32(UInt32(items.count), to: &buf)
        for item in items {
            FfiConverterTypeItemMatch.write(item, into: &buf)
        }
        return Data(buf)
    }

    static func decode(_ data: Data) -> iOSFeedSnapshot? {
        var offset = data.startIndex
        guard readBytes(magic.count, from: data, at: &offset).map(Array.init) == magic,
              readUInt32(from: data, at: &offset) == formatVersion,
              let versionLength = readUInt32(from: data, at: &offset),
              let versionBytes = readBytes(Int(versionLength), from: data, at: &offset),
              Array(versionBytes) == appVersionStamp,
              let totalCount = readUInt32(from: data, at: &offset),
              let itemCount = readUInt32(from: data, at: &offset),
              itemCount <= UInt32(maxItems)
        else { return nil }

        var reader = (data: data, offset: offset)
        var items: [ItemMatch] = []
        items.reserveCapacity(Int(itemCount))
        do {
            for _ in 0 ..< itemCount {
                try items.append(FfiConverterTypeItemMatch.read(from: &reader))
            }
        } catch {
            return nil
        }
        return iOSFeedSnapshot(items: items, totalCount: Int(totalCount))
    }

    private static func appendUInt32(_ value: UInt32, to buf: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { buf.append(contentsOf: $0) }
    }

    private static func readUInt32(from data: Data, at offset: inout Data.Index) -> UInt32? {
        guard let bytes = readBytes(4, from: data, at: &offset) else { return nil }
        return Array(bytes).withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }
    }

    private static func readBytes(
        _ count: Int,
        from data: Data,
        at offset: inout Data.Index
    ) -> Data.SubSequence? {
        guard count >= 0,
              let end = data.index(offset, offsetBy: count, limitedBy: data.endIndex)
        else { return nil }
        defer { offset = end }
        return data[offset ..< end]
    }
}
