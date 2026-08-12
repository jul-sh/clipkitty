import AppKit
import Foundation

// MARK: - Pasteboard Protocols

/// Protocol for clipboard access, enabling mock injection for testing
public protocol PasteboardProtocol: AnyObject {
    var changeCount: Int { get }
    @discardableResult func clearContents() -> Int
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool
    func setData(_ data: Data?, forType type: NSPasteboard.PasteboardType) -> Bool
    func setPropertyList(_ plist: Any, forType type: NSPasteboard.PasteboardType) -> Bool
    func declareTypes(_ newTypes: [NSPasteboard.PasteboardType], owner newOwner: Any?) -> Int
    func string(forType type: NSPasteboard.PasteboardType) -> String?
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
    func types() -> [NSPasteboard.PasteboardType]?
    func readFileURLs() -> [URL]
}

// MARK: - NSPasteboard Conformance

extension NSPasteboard: PasteboardProtocol {
    public func types() -> [NSPasteboard.PasteboardType]? {
        return types
    }

    public func readFileURLs() -> [URL] {
        let urls = readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL]
        return urls ?? []
    }
}

// MARK: - Workspace Protocol

/// Protocol for workspace access, enabling mock injection for testing
/// Note: NSWorkspace's icon methods are thread-safe, so no @MainActor needed
public protocol WorkspaceProtocol {
    var frontmostApplication: NSRunningApplication? { get }
    var notificationCenter: NotificationCenter { get }
}

// MARK: - NSWorkspace Conformance

extension NSWorkspace: WorkspaceProtocol {}

// MARK: - File Manager Protocol

/// Protocol for file system access, enabling mock injection for testing
public protocol FileManagerProtocol {
    func createDirectory(at url: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws
    func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL]
}

extension FileManager: FileManagerProtocol {}
