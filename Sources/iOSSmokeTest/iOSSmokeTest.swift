// Compile-time proof that the shared module chain builds for iOS.
//
// This file imports every shared library target. If any of them
// accidentally pull in AppKit or other macOS-only frameworks, the
// iOS build for this target will fail — surfacing the leak as a
// compiler error rather than a doc claim.
//
// This target is intentionally minimal: it exists only to be built,
// never shipped.

import ClipKittyAppleServices
import ClipKittyRust
import ClipKittyShared
import ClipKittyShortcuts
import SwiftUI

@main
struct ClipKittyiOSSmokeApp: App {
    var body: some Scene {
        WindowGroup {
            Text("ClipKitty iOS Smoke Test")
        }
    }
}
