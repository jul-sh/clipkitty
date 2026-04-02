import AppKit
@testable import ClipKitty
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

    func propertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        return storage[type]
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
        dataReadTypes = []
        stringReadTypes = []
        typesReadCount = 0
        fileURLReadCount = 0
    }
}

// MARK: - Mock Workspace

/// Mock workspace for unit testing
final class MockWorkspace: WorkspaceProtocol, @unchecked Sendable {
    var frontmostApplication: NSRunningApplication?
    let notificationCenter = NotificationCenter()

    private var fileIcons: [String: NSImage] = [:]
    private var typeIcons: [String: NSImage] = [:]
    private var bundleIDToURL: [String: URL] = [:]
    private var opener: ((URL) -> Void)?

    func icon(forFile path: String) -> NSImage {
        return fileIcons[path] ?? NSImage()
    }

    func icon(forFileType type: String) -> NSImage {
        return typeIcons[type] ?? NSImage()
    }

    func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL? {
        bundleIDToURL[bundleIdentifier]
    }

    func urlForApplication(toOpen url: URL) -> URL? {
        bundleIDToURL[url.absoluteString]
    }

    @discardableResult
    func open(_ url: URL) -> Bool {
        opener?(url)
        return true
    }

    // MARK: - Test Helpers

    func setIcon(_ icon: NSImage, forFile path: String) {
        fileIcons[path] = icon
    }

    func setIcon(_ icon: NSImage, forFileType type: String) {
        typeIcons[type] = icon
    }

    func setApplicationURL(_ url: URL, forBundleIdentifier bundleIdentifier: String) {
        bundleIDToURL[bundleIdentifier] = url
    }

    func setApplicationURLToOpen(_ appURL: URL, forTargetURL url: URL) {
        bundleIDToURL[url.absoluteString] = appURL
    }

    func setOpenHandler(_ handler: @escaping (URL) -> Void) {
        opener = handler
    }
}

// MARK: - Mock File Manager

/// Mock file manager for unit testing
final class MockFileManager: FileManagerProtocol {
    private var files: Set<String> = []
    private var directories: [String: [String]] = [:]
    private var attributes: [String: [FileAttributeKey: Any]] = [:]
    private var searchPaths: [FileManager.SearchPathDirectory: [URL]] = [:]
    private var fileData: [String: Data] = [:]
    var homeDirectoryForCurrentUser = URL(fileURLWithPath: "/Users/tester")

    func fileExists(atPath path: String) -> Bool {
        return files.contains(path)
    }

    func contents(atPath path: String) -> Data? {
        fileData[path]
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

    func createDirectory(at url: URL, withIntermediateDirectories _: Bool, attributes _: [FileAttributeKey: Any]?) throws {
        directories[url.path] = []
    }

    func urls(for directory: FileManager.SearchPathDirectory, in _: FileManager.SearchPathDomainMask) -> [URL] {
        return searchPaths[directory] ?? []
    }

    func removeItem(at url: URL) throws {
        files.remove(url.path)
        directories.removeValue(forKey: url.path)
        attributes.removeValue(forKey: url.path)
        fileData.removeValue(forKey: url.path)
    }

    // MARK: - Test Helpers

    func addFile(_ path: String, attributes: [FileAttributeKey: Any] = [:], data: Data? = nil) {
        files.insert(path)
        self.attributes[path] = attributes
        if let data {
            fileData[path] = data
        }
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
