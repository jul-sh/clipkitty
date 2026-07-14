import ClipKittyShared
import Foundation
import Observation

/// Hands incoming `clipkitty://` links from the scene to whichever view acts
/// on them. Lives on the App struct (not AppState) so a link that arrives
/// while the app is still bootstrapping — the common case when the keyboard
/// extension cold-starts the app — is held until the feed exists to consume
/// it. Consuming clears the link, so a rebuilt view tree after suspend/resume
/// never replays an old one.
@MainActor
@Observable
final class DeepLinkRouter {
    private(set) var pending: AppDeepLink?

    func open(_ link: AppDeepLink) {
        pending = link
    }

    /// Returns the pending link and clears it; nil if there is none.
    func consume() -> AppDeepLink? {
        defer { pending = nil }
        return pending
    }
}
