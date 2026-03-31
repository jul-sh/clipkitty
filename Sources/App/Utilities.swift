import CryptoKit
import Foundation

/// macOS-specific utility functions
enum Utilities {
    /// Format bytes into human-readable size string
    static func formatBytes(_ bytes: Int64) -> String {
        FormattingHelpers.formatBytes(bytes)
    }

    /// Compute SHA-256 hash of a file
    static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
