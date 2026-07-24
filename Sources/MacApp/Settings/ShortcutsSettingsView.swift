import KeyboardShortcuts
import SwiftUI

struct ShortcutsSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var showHistoryShortcut: KeyboardShortcuts.Shortcut?

    init() {
        _showHistoryShortcut = State(initialValue: KeyboardShortcuts.Name.showClipboardHistory.shortcut)
    }

    private var deleteItemShortcut: Binding<KeyboardShortcuts.Shortcut?> {
        Binding(
            get: {
                switch settings.deleteItemShortcutSetting {
                case let .enabled(shortcut):
                    return shortcut
                case .disabled:
                    return nil
                }
            },
            set: { shortcut in
                switch shortcut {
                case let .some(shortcut):
                    settings.deleteItemShortcutSetting = .enabled(shortcut)
                case .none:
                    settings.deleteItemShortcutSetting = .disabled
                }
            }
        )
    }

    var body: some View {
        Form {
            Section(String(localized: "Keyboard Shortcut")) {
                HStack {
                    KeyboardShortcuts.Recorder(
                        String(localized: "Open ClipKitty"),
                        name: .showClipboardHistory,
                        onChange: { showHistoryShortcut = $0 }
                    )
                    .shortcutValidation(validateShowHistoryShortcut)

                    restoreButton {
                        KeyboardShortcuts.reset(.showClipboardHistory)
                        showHistoryShortcut = .defaultShowClipboardHistory
                    }
                    .disabled(showHistoryShortcut == .defaultShowClipboardHistory)
                }

                HStack {
                    KeyboardShortcuts.Recorder(
                        String(localized: "Delete Item"),
                        shortcut: deleteItemShortcut
                    )
                    .shortcutValidation(validateDeleteItemShortcut)

                    restoreButton {
                        settings.deleteItemShortcutSetting = .enabled(.defaultDeleteSelectedItem)
                    }
                    .disabled(settings.deleteItemShortcutSetting == .enabled(.defaultDeleteSelectedItem))
                }
            }
        }
        .formStyle(.grouped)
    }

    private func validateShowHistoryShortcut(
        _ shortcut: KeyboardShortcuts.Shortcut
    ) -> KeyboardShortcuts.ValidationResult {
        switch settings.deleteItemShortcutSetting {
        case let .enabled(deleteShortcut) where deleteShortcut == shortcut:
            return .disallow(reason: shortcutConflictReason(for: String(localized: "Delete Item")))
        case .enabled, .disabled:
            return .allow
        }
    }

    private func validateDeleteItemShortcut(
        _ shortcut: KeyboardShortcuts.Shortcut
    ) -> KeyboardShortcuts.ValidationResult {
        guard shortcut == KeyboardShortcuts.Name.showClipboardHistory.shortcut else {
            return .allow
        }

        return .disallow(reason: shortcutConflictReason(for: String(localized: "Open ClipKitty")))
    }

    private func restoreButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(String(localized: "Restore Default"))
        .accessibilityLabel(String(localized: "Restore Default"))
    }
}
