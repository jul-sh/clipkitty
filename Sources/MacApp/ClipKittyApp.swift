import AppKit
import SwiftUI

extension Notification.Name {
    static let clipKittyOpenSettings = Notification.Name("ClipKittyOpenSettings")
}

// The real settings window is managed by AppDelegate; this placeholder forwards
// the ⌘, shortcut that macOS routes to the SwiftUI Settings scene.
private struct SettingsShortcutForwarder: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .clipKittyOpenSettings, object: nil)
            view.window?.close()
        }
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
}

@main
struct ClipKittyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsShortcutForwarder()
        }
    }
}
