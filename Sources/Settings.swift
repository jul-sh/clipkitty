import Foundation
import Carbon

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

    @Published var maxDatabaseSizeMB: Int {
        didSet { save() }
    }

    private let defaults = UserDefaults.standard
    private let hotKeyKey = "hotKey"
    private let maxDbSizeKey = "maxDatabaseSizeMB"

    private init() {
        if let data = defaults.data(forKey: hotKeyKey),
           let decoded = try? JSONDecoder().decode(HotKey.self, from: data) {
            hotKey = decoded
        } else {
            hotKey = .default
        }

        maxDatabaseSizeMB = defaults.integer(forKey: maxDbSizeKey)
        if maxDatabaseSizeMB == 0 {
            maxDatabaseSizeMB = 2048 // Default 2 GB
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hotKey) {
            defaults.set(data, forKey: hotKeyKey)
        }
        defaults.set(maxDatabaseSizeMB, forKey: maxDbSizeKey)
    }
}
