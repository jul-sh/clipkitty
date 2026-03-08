import AppKit
import Foundation

// MARK: - Pasteboard Protocol (duplicated for test target)

/// Protocol for clipboard access, enabling mock injection for testing
protocol PasteboardProtocol: AnyObject {
    var changeCount: Int { get }
    @discardableResult func clearContents() -> Int
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool
    func setData(_ data: Data?, forType type: NSPasteboard.PasteboardType) -> Bool
    func setPropertyList(_ plist: Any, forType type: NSPasteboard.PasteboardType) -> Bool
    func declareTypes(_ newTypes: [NSPasteboard.PasteboardType], owner newOwner: Any?) -> Int
    func string(forType type: NSPasteboard.PasteboardType) -> String?
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
    func types() -> [NSPasteboard.PasteboardType]?
    func propertyList(forType type: NSPasteboard.PasteboardType) -> Any?
}

extension NSPasteboard: PasteboardProtocol {
    func types() -> [NSPasteboard.PasteboardType]? {
        return self.types
    }
}

// MARK: - Mock Pasteboard

/// Mock pasteboard for unit testing clipboard operations
final class MockPasteboard: PasteboardProtocol {
    private(set) var changeCount: Int = 0
    private var storage: [NSPasteboard.PasteboardType: Any] = [:]
    private var declaredTypes: [NSPasteboard.PasteboardType] = []

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

    func declareTypes(_ newTypes: [NSPasteboard.PasteboardType], owner newOwner: Any?) -> Int {
        declaredTypes = newTypes
        changeCount += 1
        return changeCount
    }

    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        return storage[type] as? String
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        return storage[type] as? Data
    }

    func types() -> [NSPasteboard.PasteboardType]? {
        return declaredTypes.isEmpty ? Array(storage.keys) : declaredTypes
    }

    func propertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        return storage[type]
    }

    // MARK: - Test Helpers

    /// Simulate external clipboard change
    func simulateExternalChange(string: String) {
        storage[.string] = string
        changeCount += 1
    }

    /// Reset to initial state
    func reset() {
        storage.removeAll()
        declaredTypes.removeAll()
        changeCount = 0
    }
}

// MARK: - Mock Workspace

/// Mock workspace for unit testing
final class MockWorkspace: @unchecked Sendable {
    var frontmostApplication: NSRunningApplication?

    private var fileIcons: [String: NSImage] = [:]
    private var typeIcons: [String: NSImage] = [:]

    func icon(forFile path: String) -> NSImage {
        return fileIcons[path] ?? NSImage()
    }

    func icon(forFileType type: String) -> NSImage {
        return typeIcons[type] ?? NSImage()
    }

    // MARK: - Test Helpers

    func setIcon(_ icon: NSImage, forFile path: String) {
        fileIcons[path] = icon
    }

    func setIcon(_ icon: NSImage, forFileType type: String) {
        typeIcons[type] = icon
    }
}

// MARK: - Mock File Manager

/// Mock file manager for unit testing
final class MockFileManager {
    private var files: Set<String> = []
    private var directories: [String: [String]] = [:]
    private var attributes: [String: [FileAttributeKey: Any]] = [:]
    private var searchPaths: [FileManager.SearchPathDirectory: [URL]] = [:]

    func fileExists(atPath path: String) -> Bool {
        return files.contains(path)
    }

    func contentsOfDirectory(atPath path: String) throws -> [String] {
        guard let contents = directories[path] else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        }
        return contents
    }

    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        guard let attrs = attributes[path] else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        }
        return attrs
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool, attributes attrs: [FileAttributeKey: Any]?) throws {
        directories[url.path] = []
    }

    func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        return searchPaths[directory] ?? []
    }

    // MARK: - Test Helpers

    func addFile(_ path: String, attributes: [FileAttributeKey: Any] = [:]) {
        files.insert(path)
        self.attributes[path] = attributes
    }

    func addDirectory(_ path: String, contents: [String] = []) {
        directories[path] = contents
    }

    func setSearchPath(_ urls: [URL], for directory: FileManager.SearchPathDirectory) {
        searchPaths[directory] = urls
    }

    func reset() {
        files.removeAll()
        directories.removeAll()
        attributes.removeAll()
        searchPaths.removeAll()
    }
}
