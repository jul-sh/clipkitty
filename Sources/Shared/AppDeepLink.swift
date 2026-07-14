import Foundation

/// Deep links into the main iOS app, used by the extensions (the keyboard has
/// no UI of its own for anything beyond the recent-clips strip, so e.g. search
/// hands off to the app). One enum owns both sides: extensions build URLs from
/// a case, the app parses incoming URLs back into one.
public enum AppDeepLink: String, Sendable {
    /// Open the app with the search field active and focused.
    case search

    public static let scheme = "clipkitty"

    public var url: URL {
        URL(string: "\(Self.scheme)://\(rawValue)")!
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        // "clipkitty://search" parses the action name as the host; accept a
        // path form ("clipkitty:///search") too.
        let name = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.init(rawValue: name.lowercased())
    }
}
