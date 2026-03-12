import CryptoKit
import Foundation

/// Shared utility functions used across ClipKitty
enum Utilities {
    /// Format bytes into human-readable size string
    /// - Parameter bytes: Number of bytes (can be negative)
    /// - Returns: Formatted string like "1.2 GB", "500 MB", "10 KB", or "42 bytes"
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

    /// Compute SHA-256 hash of a file
    /// - Parameter url: File URL to hash
    /// - Returns: Lowercase hex string of the hash, or nil if file cannot be read
    static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
