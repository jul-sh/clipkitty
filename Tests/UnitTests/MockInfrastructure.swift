import AppKit
@testable import ClipKitty
@testable import ClipKittyMacPlatform
import Foundation

// MARK: - Mock Pasteboard

/// Mock pasteboard for unit testing clipboard operations
final class MockPasteboard: PasteboardProtocol {
    private(set) var changeCount: Int = 0
    private var storage: [NSPasteboard.PasteboardType: Any] = [:]
    private var declaredTypes: [NSPasteboard.PasteboardType] = []
    private(set) var dataReadTypes: [NSPasteboard.PasteboardType] = []
    private(set) var stringReadTypes: [NSPasteboard.PasteboardType] = []
    private(set) var typesReadCount: Int = 0
    private(set) var fileURLReadCount: Int = 0

    @discardableResult
    func clearContents() -> Int {
        storage.removeAll()
        declaredTypes.removeAll()
        changeCount += 1
        return changeCount
    }

    @discardableResult
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        storage[type] = string
        changeCount += 1
        return true
    }

    @discardableResult
    func setData(_ data: Data?, forType type: NSPasteboard.PasteboardType) -> Bool {
        if let data {
            storage[type] = data
        } else {
            storage.removeValue(forKey: type)
        }
        changeCount += 1
        return true
    }

    @discardableResult
    func setPropertyList(_ plist: Any, forType type: NSPasteboard.PasteboardType) -> Bool {
        storage[type] = plist
        changeCount += 1
        return true
    }

    func declareTypes(_ newTypes: [NSPasteboard.PasteboardType], owner _: Any?) -> Int {
        declaredTypes = newTypes
        changeCount += 1
        return changeCount
    }

    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        stringReadTypes.append(type)
        return storage[type] as? String
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        dataReadTypes.append(type)
        return storage[type] as? Data
    }

    func types() -> [NSPasteboard.PasteboardType]? {
        typesReadCount += 1
        return declaredTypes.isEmpty ? Array(storage.keys) : declaredTypes
    }

    func readFileURLs() -> [URL] {
        fileURLReadCount += 1
        guard let fileURL = storage[.fileURL] as? String,
              let url = URL(string: fileURL)
        else {
            return []
        }
        return [url]
    }
}

// MARK: - Mock Workspace

/// Mock workspace for unit testing
final class MockWorkspace: WorkspaceProtocol, @unchecked Sendable {
    var frontmostApplication: NSRunningApplication?
    let notificationCenter = NotificationCenter()
}
