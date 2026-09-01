import SwiftUI

/// The pages of first-launch onboarding, in order. Each page is a distinct
/// screen with its own hero, copy, and actions; `OnboardingScreen` switches
/// over this rather than indexing into a page array so a new page cannot be
/// added without deciding what it renders.
enum OnboardingPage: CaseIterable {
    /// App identity and the one-line pitch.
    case welcome
    /// Cross-device sync, offering to turn iCloud sync on.
    case sync
    /// Saving content from other apps via the share sheet.
    case share
    /// The "Paste from Other Apps" permission behind Auto-Add.
    case pasteAccess

    /// The page reached by advancing from this one, or `nil` on the last page,
    /// where advancing finishes onboarding instead.
    var next: OnboardingPage? {
        switch self {
        case .welcome: return .sync
        case .sync: return .share
        case .share: return .pasteAccess
        case .pasteAccess: return nil
        }
    }

    /// The page a back gesture returns to, or `nil` on the first page, which
    /// has no back button.
    var previous: OnboardingPage? {
        switch self {
        case .welcome: return nil
        case .sync: return .welcome
        case .share: return .sync
        case .pasteAccess: return .share
        }
    }
}

/// Where the user is in onboarding, and — on the permission page — whether the
/// system paste alert has already been raised.
///
/// The probe state lives inside `.pasteAccess` because it is meaningless on
/// every other page: no other page can have a probe in flight, so no other
/// state can carry one.
enum OnboardingFlowState {
    case page(OnboardingPage)
    /// A paste probe is in flight on the permission page. The system alert is
    /// on screen, or its allowed one-time read is being materialized.
    case probingPasteAccess
    /// The probe finished. Regardless of how the user answered the system
    /// alert, the how-to sheet is shown: "Allow Paste" in that alert grants a
    /// single read, not the persistent "Allow" setting that Auto-Add needs.
    case explainingPasteAccess

    /// The page currently rendered behind any sheet or alert.
    var visiblePage: OnboardingPage {
        switch self {
        case let .page(page):
            return page
        case .probingPasteAccess, .explainingPasteAccess:
            return .pasteAccess
        }
    }
}
