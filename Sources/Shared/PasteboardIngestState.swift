import Foundation

/// Cross-process record of the last pasteboard generation ClipKitty ingested —
/// or deliberately skipped, honouring a declined paste prompt. Both the app's
/// auto-add and the keyboard's capture consult it, so the same clipboard
/// content is never saved twice and the same generation never re-prompts.
///
/// Lives in App Group `UserDefaults` because `changeCount` coordination has to
/// span the app and the keyboard extension; `UserDefaults.standard` is
/// per-process. `changeCount` values are compared by equality, never ordering —
/// the counter resets on reboot.
public enum PasteboardIngestState {
    private static let changeCountKey = "lastIngestedPasteboardChangeCount"

    public static var appGroupDefaults: UserDefaults? {
        UserDefaults(suiteName: DatabasePath.appGroupId)
    }

    /// The last pasteboard `changeCount` ingested or skipped, nil if none was
    /// ever recorded. `defaults` overrides the App Group suite for tests.
    public static func lastChangeCount(defaults: UserDefaults? = nil) -> Int? {
        (defaults ?? appGroupDefaults)?.object(forKey: changeCountKey) as? Int
    }

    public static func recordChangeCount(_ count: Int, defaults: UserDefaults? = nil) {
        (defaults ?? appGroupDefaults)?.set(count, forKey: changeCountKey)
    }
}
