import SwiftUI

/// Resolves a small badge icon for the app a clipboard item was copied from.
///
/// On macOS the source-app badge is the *real* app icon, fetched via
/// `NSWorkspace.icon(forFile:)` from the app's bundle (see
/// `RowIconCache.sourceAppImage` in `BrowserItemRow.swift`). iOS has no
/// equivalent: there is no API to turn another app's bundle identifier into its
/// icon, and a sandboxed app can't introspect other installed apps. Items
/// captured on iOS also carry no bundle id at all.
///
/// So on iOS we approximate the macOS badge only when we have a recognizable
/// bundle id (e.g. `com.apple.Safari`) that can map to a representative SF
/// Symbol. Unknown apps show no badge rather than an empty generic outline.
enum SourceAppIcon {
    /// The SF Symbol that best represents the given source app bundle id, or
    /// `nil` when there's nothing useful to show.
    static func symbolName(forBundleID bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }

        if let exact = exactMatches[bundleID] {
            return exact
        }

        // Fall back to coarse matching on the bundle id so related apps and
        // unrecognised first-party apps still get a sensible glyph.
        let lowered = bundleID.lowercased()
        for (fragment, symbol) in fragmentMatches where lowered.contains(fragment) {
            return symbol
        }

        return nil
    }

    /// Exact bundle-id → SF Symbol mapping for common macOS sources.
    private static let exactMatches: [String: String] = [
        "com.apple.Safari": "safari",
        "com.apple.SafariTechnologyPreview": "safari",
        "com.apple.mail": "envelope",
        "com.apple.MobileSMS": "message",
        "com.apple.iChat": "message",
        "com.apple.Notes": "note.text",
        "com.apple.Terminal": "terminal",
        "com.apple.TextEdit": "doc.text",
        "com.apple.dt.Xcode": "hammer",
        "com.apple.finder": "folder",
        "com.apple.Preview": "doc.richtext",
        "com.apple.Photos": "photo",
        "com.apple.reminders": "checklist",
        "com.apple.iCal": "calendar",
        "com.apple.AddressBook": "person.crop.circle",
        "com.apple.Music": "music.note",
        "com.apple.podcasts": "mic",
        "com.apple.freeform": "scribble",
        "com.apple.systempreferences": "gearshape",
    ]

    /// Substring → SF Symbol fallbacks, checked when there's no exact match.
    /// Ordered most-specific first.
    private static let fragmentMatches: [(String, String)] = [
        ("chrome", "globe"),
        ("firefox", "globe"),
        ("microsoftedge", "globe"),
        ("com.brave", "globe"),
        ("com.operasoftware", "globe"),
        ("arc", "globe"),
        ("safari", "safari"),
        ("slack", "number"),
        ("discord", "bubble.left.and.bubble.right"),
        ("whatsapp", "message"),
        ("telegram", "paperplane"),
        ("notion", "note.text"),
        ("obsidian", "note.text"),
        ("vscode", "chevron.left.forwardslash.chevron.right"),
        ("visualstudio", "chevron.left.forwardslash.chevron.right"),
        ("jetbrains", "chevron.left.forwardslash.chevron.right"),
        ("iterm", "terminal"),
        ("terminal", "terminal"),
        ("mail", "envelope"),
        ("photo", "photo"),
        ("music", "music.note"),
        ("spotify", "music.note"),
        ("calendar", "calendar"),
        ("note", "note.text"),
        ("word", "doc.text"),
        ("excel", "tablecells"),
        ("powerpoint", "rectangle.on.rectangle"),
        ("figma", "pencil.and.outline"),
        ("preview", "doc.richtext"),
        ("finder", "folder"),
    ]
}
