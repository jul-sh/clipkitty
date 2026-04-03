import Foundation
import SwiftUI

/// Coordinates top-level navigation and deep links from Siri Shortcuts.
@MainActor
@Observable
final class AppRouter {
    enum Tab {
        case library
        case settings
    }

    enum DeepLink {
        case search(query: String)
        case newItem
    }

    var selectedTab: Tab = .library

    /// Pending deep link to apply once the library tab is visible.
    var pendingDeepLink: DeepLink?

    func handle(_ deepLink: DeepLink) {
        selectedTab = .library
        pendingDeepLink = deepLink
    }

    func consumeDeepLink() -> DeepLink? {
        defer { pendingDeepLink = nil }
        return pendingDeepLink
    }

    func handleURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "clipkitty"
        else { return }

        switch components.host {
        case "search":
            let query = components.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
            handle(.search(query: query))
        case "add":
            handle(.newItem)
        default:
            break
        }
    }
}
