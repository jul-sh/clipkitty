import AppKit
import SwiftUI

extension Notification.Name {
    static let clipKittyOpenSettings = Notification.Name("ClipKittyOpenSettings")
}

@main
struct ClipKittyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(NSLocalizedString("Settings...", comment: "Command menu item to open settings window")) {
                    NotificationCenter.default.post(name: .clipKittyOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
