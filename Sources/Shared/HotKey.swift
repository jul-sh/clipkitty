import Foundation

public struct HotKey: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public static let `default` = HotKey(keyCode: 49, modifiers: UInt32(0x0800)) // Option+Space (optionKey = 0x0800)

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    private static let keyCodeNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
        38: "J", 40: "K", 45: "N", 46: "M",
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete",
        53: "Escape", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    /// Menu key equivalent strings (lowercase single char, or special char)
    private static let keyCodeEquivalents: [UInt32: String] = [
        49: " ", 36: "\r", 48: "\t",
    ]

    public var displayString: String {
        var parts: [String] = []
        if modifiers & UInt32(0x1000) != 0 { parts.append("⌃") }  // controlKey
        if modifiers & UInt32(0x0800) != 0 { parts.append("⌥") }  // optionKey
        if modifiers & UInt32(0x0200) != 0 { parts.append("⇧") }  // shiftKey
        if modifiers & UInt32(0x0100) != 0 { parts.append("⌘") }  // cmdKey
        parts.append(Self.keyCodeNames[keyCode] ?? "Key\(keyCode)")
        return parts.joined()
    }

    /// Key equivalent string for NSMenuItem
    public var keyEquivalent: String {
        if let special = Self.keyCodeEquivalents[keyCode] { return special }
        return Self.keyCodeNames[keyCode]?.lowercased() ?? ""
    }
}
