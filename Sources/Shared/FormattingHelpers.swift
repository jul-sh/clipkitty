import Foundation

enum FormattingHelpers {
    /// Format bytes into human-readable size string
    static func formatBytes(_ bytes: Int64) -> String {
        let absBytes = abs(bytes)
        let kb = Double(absBytes) / 1024
        let mb = kb / 1024
        let gb = mb / 1024

        if gb >= 1 {
            return String(localized: "\(gb, specifier: "%.2f") GB")
        } else if mb >= 1 {
            return String(localized: "\(mb, specifier: "%.1f") MB")
        } else if kb >= 1 {
            return String(localized: "\(kb, specifier: "%.0f") KB")
        } else {
            return String(localized: "\(absBytes) bytes")
        }
    }

    /// Format bytes (Int) into human-readable size string.
    static func formatBytes(_ bytes: Int) -> String {
        formatBytes(Int64(bytes))
    }

    /// Format a Unix timestamp into a human-readable date string.
    static func formatDate(timestampUnix: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestampUnix))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Format a Unix timestamp as a relative time string (e.g., "2 min ago").
    static func timeAgo(from timestampUnix: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestampUnix))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Parse a hex color string (e.g., "#FF5733") into RGBA components.
    /// Returns (red, green, blue, alpha) in 0.0–1.0 range, or nil if parsing fails.
    static func parseHexColor(_ colorString: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        let hex = colorString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        guard hex.count == 6 || hex.count == 8,
              let value = UInt64(hex, radix: 16)
        else { return nil }

        if hex.count == 8 {
            return (
                r: Double((value >> 24) & 0xFF) / 255.0,
                g: Double((value >> 16) & 0xFF) / 255.0,
                b: Double((value >> 8) & 0xFF) / 255.0,
                a: Double(value & 0xFF) / 255.0
            )
        } else {
            return (
                r: Double((value >> 16) & 0xFF) / 255.0,
                g: Double((value >> 8) & 0xFF) / 255.0,
                b: Double(value & 0xFF) / 255.0,
                a: 1.0
            )
        }
    }

    /// Convert a packed RGBA UInt32 to (r, g, b, a) in 0.0–1.0 range.
    static func colorFromRGBA(_ rgba: UInt32) -> (r: Double, g: Double, b: Double, a: Double) {
        (
            r: Double((rgba >> 24) & 0xFF) / 255.0,
            g: Double((rgba >> 16) & 0xFF) / 255.0,
            b: Double((rgba >> 8) & 0xFF) / 255.0,
            a: Double(rgba & 0xFF) / 255.0
        )
    }

    /// Map a source app bundle ID to an SF Symbol name.
    static func sourceAppIcon(bundleId: String) -> String? {
        let id = bundleId.lowercased()
        if id.contains("safari") { return "safari" }
        if id.contains("mail") { return "envelope" }
        if id.contains("notes") { return "note.text" }
        if id.contains("messages") { return "message" }
        if id.contains("slack") { return "number" }
        if id.contains("terminal") || id.contains("iterm") { return "terminal" }
        if id.contains("xcode") { return "hammer" }
        if id.contains("finder") { return "folder" }
        if id.contains("textedit") { return "doc.text" }
        if id.contains("preview") { return "eye" }
        return nil
    }
}
