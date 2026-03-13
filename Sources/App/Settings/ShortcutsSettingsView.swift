import AppKit
import SwiftUI

struct ShortcutsSettingsView: View {
    private struct ShortcutItem: Identifiable {
        enum Availability {
            case always
            case withSelection
            case whileEditing
        }

        let id: String
        let action: LocalizedStringKey
        let shortcut: String
        let description: LocalizedStringKey
        let availability: Availability
    }

    @ObservedObject private var settings = AppSettings.shared
    @State private var hotKeyState: HotKeyEditState = .idle

    let onHotKeyChanged: (HotKey) -> Void

    private let browserShortcuts: [ShortcutItem] = [
        .init(
            id: "navigate",
            action: "Move selection",
            shortcut: "↑ / ↓",
            description: "Browse clipboard items without leaving the keyboard.",
            availability: .always
        ),
        .init(
            id: "confirm",
            action: "Paste or copy selected item",
            shortcut: "Return",
            description: "Uses your current paste mode setting.",
            availability: .withSelection
        ),
        .init(
            id: "quick-jump",
            action: "Paste item 1-9",
            shortcut: "⌘1-9",
            description: "Instantly picks and pastes one of the first nine results.",
            availability: .always
        ),
        .init(
            id: "filter",
            action: "Open content filters",
            shortcut: "Tab",
            description: "Shows the filter picker so you can switch between text, images, links, and more.",
            availability: .always
        ),
        .init(
            id: "actions",
            action: "Open item actions",
            shortcut: "⌘K",
            description: "Shows actions for the selected item, including bookmark, copy or paste, and delete.",
            availability: .withSelection
        ),
        .init(
            id: "delete",
            action: "Delete selected item",
            shortcut: "Delete or ⌘Delete",
            description: "Removes the current item from history.",
            availability: .withSelection
        ),
        .init(
            id: "dismiss",
            action: "Close panel or popover",
            shortcut: "Escape",
            description: "Dismisses the current overlay, or closes ClipKitty when no overlay is open.",
            availability: .always
        ),
        .init(
            id: "save-edit",
            action: "Save current edit",
            shortcut: "⌘S",
            description: "Available while editing a text item in the preview pane.",
            availability: .whileEditing
        ),
        .init(
            id: "confirm-edit",
            action: "Save and paste or copy edit",
            shortcut: "⌘Return",
            description: "Available while the preview editor has focus.",
            availability: .whileEditing
        ),
    ]

    var body: some View {
        Form {
            Section(String(localized: "Global Shortcut")) {
                HStack {
                    Text(String(localized: "Open ClipKitty"))
                    Spacer()
                    Button(action: { hotKeyState = .recording }) {
                        let state = hotKeyState
                        let labelAndBackground: (String, Color) = {
                            switch state {
                            case .recording:
                                return (String(localized: "Press keys..."), Color.accentColor.opacity(0.2))
                            case .idle:
                                return (settings.hotKey.displayString, Color.secondary.opacity(0.1))
                            }
                        }()

                        Text(labelAndBackground.0)
                            .frame(minWidth: 100)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(labelAndBackground.1)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                .background(
                    HotKeyRecorder(
                        state: $hotKeyState,
                        onHotKeyRecorded: { hotKey in
                            settings.hotKey = hotKey
                            onHotKeyChanged(hotKey)
                        }
                    )
                )

                if settings.hotKey != .default {
                    Button(String(localized: "Reset to Default (⌥Space)")) {
                        settings.hotKey = .default
                        onHotKeyChanged(.default)
                    }
                    .font(.subheadline)
                }

                Text("This is the only shortcut you can customize. The rest are built into the browser so they stay consistent everywhere.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Browser Shortcuts")) {
                Text("These shortcuts work inside the clipboard browser. Some are always available, while others only appear when an item is selected or when you are editing.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ForEach(browserShortcuts) { shortcut in
                    shortcutRow(shortcut)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func shortcutRow(_ shortcut: ShortcutItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(shortcut.action)
                    Text(availabilityText(for: shortcut.availability))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(shortcut.shortcut)
                    .font(.custom(FontManager.mono, size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("Shortcut_\(shortcut.id)")
            }

            Text(shortcut.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func availabilityText(for availability: ShortcutItem.Availability) -> LocalizedStringKey {
        switch availability {
        case .always:
            "Always available"
        case .withSelection:
            "When an item is selected"
        case .whileEditing:
            "While editing in the preview pane"
        }
    }
}
