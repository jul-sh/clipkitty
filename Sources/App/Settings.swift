import Foundation
import Carbon
import AppKit

struct HotKey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let `default` = HotKey(keyCode: 49, modifiers: UInt32(optionKey)) // Option+Space

    var displayString: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(keyCodeToString(keyCode))
        return parts.joined()
    }

    /// Key equivalent string for NSMenuItem
    var keyEquivalent: String {
        let keyMap: [UInt32: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
            8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
            16: "y", 17: "t", 31: "o", 32: "u", 34: "i", 35: "p", 37: "l",
            38: "j", 40: "k", 45: "n", 46: "m",
            49: " ", // Space
            36: "\r", // Return
            48: "\t", // Tab
        ]
        return keyMap[keyCode] ?? ""
    }

    /// Modifier mask for NSMenuItem
    var modifierMask: NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        return mask
    }

    private func keyCodeToString(_ code: UInt32) -> String {
        let keyMap: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 40: "K", 45: "N", 46: "M",
            49: "Space", 36: "Return", 48: "Tab", 51: "Delete",
            53: "Escape", 123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        return keyMap[code] ?? "Key\(code)"
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var hotKey: HotKey {
        didSet { save() }
    }

    @Published var maxDatabaseSizeGB: Double {
        didSet { save() }
    }

    /// When true, selecting an item (Enter) pastes into the previous app. When false, just copies to clipboard.
    @Published var pasteOnSelect: Bool {
        didSet { save() }
    }

    let maxImageMegapixels: Double
    let imageCompressionQuality: Double

    /// Whether the user wants launch at login enabled (persisted preference)
    @Published var launchAtLoginEnabled: Bool {
        didSet { save() }
    }

    private let defaults = UserDefaults.standard
    private let hotKeyKey = "hotKey"
    private let maxDbSizeKey = "maxDatabaseSizeGB"
    private let legacyMaxDbSizeKey = "maxDatabaseSizeMB"
    private let pasteOnSelectKey = "pasteOnSelect"
    private let launchAtLoginKey = "launchAtLogin"

    private init() {
        // Initialize all stored properties first
        if let data = defaults.data(forKey: hotKeyKey),
           let decoded = try? JSONDecoder().decode(HotKey.self, from: data) {
            hotKey = decoded
        } else {
            hotKey = .default
        }

        if let stored = defaults.object(forKey: maxDbSizeKey) as? NSNumber {
            maxDatabaseSizeGB = stored.doubleValue
        } else if let legacyStored = defaults.object(forKey: legacyMaxDbSizeKey) as? NSNumber {
            maxDatabaseSizeGB = legacyStored.doubleValue / 1024.0
        } else {
            maxDatabaseSizeGB = 2.0
        }

        // Default to true (paste on select) for new installs
        pasteOnSelect = defaults.object(forKey: pasteOnSelectKey) as? Bool ?? true

        // Default to false - user must explicitly enable launch at login
        launchAtLoginEnabled = defaults.object(forKey: launchAtLoginKey) as? Bool ?? false

        maxImageMegapixels = 2.0
        imageCompressionQuality = 0.3
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hotKey) {
            defaults.set(data, forKey: hotKeyKey)
        }
        defaults.set(maxDatabaseSizeGB, forKey: maxDbSizeKey)
        defaults.set(pasteOnSelect, forKey: pasteOnSelectKey)
        defaults.set(launchAtLoginEnabled, forKey: launchAtLoginKey)
    }
}
