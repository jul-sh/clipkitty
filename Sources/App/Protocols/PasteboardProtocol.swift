import AppKit
import Foundation

// MARK: - Pasteboard Protocols

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
    func readFileURLs() -> [URL]
}

// MARK: - NSPasteboard Conformance

extension NSPasteboard: PasteboardProtocol {
    func types() -> [NSPasteboard.PasteboardType]? {
        return self.types
    }

    func readFileURLs() -> [URL] {
        let urls = readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL]
        return urls ?? []
    }
}

// MARK: - Workspace Protocol

/// Protocol for workspace access, enabling mock injection for testing
/// Note: NSWorkspace's icon methods are thread-safe, so no @MainActor needed
protocol WorkspaceProtocol {
    var frontmostApplication: NSRunningApplication? { get }
    var notificationCenter: NotificationCenter { get }
    func icon(forFile path: String) -> NSImage
    func icon(forFileType type: String) -> NSImage
    func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL?
    func urlForApplication(toOpen url: URL) -> URL?
    @discardableResult func open(_ url: URL) -> Bool
}

// MARK: - NSWorkspace Conformance

extension NSWorkspace: WorkspaceProtocol {}

// MARK: - File Manager Protocol

/// Protocol for file system access, enabling mock injection for testing
protocol FileManagerProtocol {
    func fileExists(atPath path: String) -> Bool
    func contents(atPath path: String) -> Data?
    func contentsOfDirectory(atPath path: String) throws -> [String]
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any]
    func createDirectory(at url: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws
    func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL]
    var homeDirectoryForCurrentUser: URL { get }
    func removeItem(at url: URL) throws
}

extension FileManager: FileManagerProtocol {}

// MARK: - Bundle Protocol

protocol BundleInfoProtocol {
    var bundleIdentifier: String? { get }
    var bundlePath: String { get }
}

extension Bundle: BundleInfoProtocol {}
