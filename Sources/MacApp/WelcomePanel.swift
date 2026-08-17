import AppKit
import ClipKittyMacPlatform
import KeyboardShortcuts
import SwiftUI

// MARK: - SwiftUI Views

private struct WelcomePageView: View {
    let onGetStarted: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 12) {
                Text("Your Clipboard, Supercharged")
                    .font(.system(size: 24, weight: .bold))

                Text(
                    "ClipKitty keeps your clipboard history at your fingertips. Copy anything and find it later, instantly."
                )
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            }

            Spacer()

            Button(action: onGetStarted) {
                Text("Get Started")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: 200)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
                .frame(height: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct QuickStartPageView: View {
    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared
    @ObservedObject private var settings = AppSettings.shared
    let onComplete: () -> Void

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: {
                switch launchAtLogin.state.registrationStatus {
                case .enabled: true
                case .disabled: false
                }
            },
            set: { newValue in
                if launchAtLogin.setEnabled(newValue) {
                    settings.launchAtLoginEnabled = newValue
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
                .frame(height: 8)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)

            Text("Quick Start")
                .font(.system(size: 22, weight: .bold))

            VStack(spacing: 14) {
                // Hotkey pane
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Activation Shortcut")
                                .font(.system(size: 13, weight: .medium))
                            Text("Open your clipboard history anytime")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .showClipboardHistory)
                            .shortcutValidation(validateShowHistoryShortcut)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.quaternary, lineWidth: 1)
                )

                HStack(spacing: 6) {
                    Image(systemName: "menubar.arrow.up.rectangle")
                        .font(.system(size: 12))
                    Text("You can also click the menu bar icon to open ClipKitty.")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    #if ENABLE_SYNTHETIC_PASTE
                        // Paste Items row
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Paste Items")
                                .font(.system(size: 13, weight: .medium))
                            PasteItemsSettingView()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        Divider()
                            .padding(.horizontal, 16)
                    #endif

                    #if ENABLE_ICLOUD_SYNC
                        // iCloud Sync row
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("iCloud Sync")
                                    .font(.system(size: 13, weight: .medium))
                                Text("Sync clipboard history across your devices")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $settings.syncEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        Divider()
                            .padding(.horizontal, 16)
                    #endif

                    // Launch at Login row
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start at Login")
                                .font(.system(size: 13, weight: .medium))
                            Text("Keep ClipKitty running in the background")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: launchAtLoginBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.quaternary, lineWidth: 1)
                )
            }
            .padding(.horizontal, 40)

            Spacer()
                .frame(height: 8)

            Button(action: onComplete) {
                Text("Got It")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: 200)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
                .frame(height: 24)
        }
        .frame(maxWidth: .infinity)
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
}

private struct ContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct WelcomeContentView: View {
    @State private var currentPage = 0
    let onComplete: () -> Void
    let onContentHeightChanged: (CGFloat) -> Void

    var body: some View {
        Group {
            if currentPage == 0 {
                WelcomePageView(onGetStarted: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentPage = 1
                    }
                })
                .frame(minHeight: 480)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            } else {
                QuickStartPageView(
                    onComplete: onComplete
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            }
        }
        .frame(width: 500)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: ContentHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ContentHeightPreferenceKey.self) { height in
            onContentHeightChanged(height)
        }
        .clipKittyWindowGlassBackground()
    }
}

// MARK: - Window Controller

@MainActor
final class WelcomeWindowController {
    private(set) var window: NSWindow?
    var onComplete: (() -> Void)?
    weak var windowDelegate: NSWindowDelegate?

    func showWindow() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = WelcomeContentView(
            onComplete: { [weak self] in
                self?.complete()
            },
            onContentHeightChanged: { [weak self] height in
                self?.updateWindowHeight(height)
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 580),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.wantsLayer = true
        if let radius = systemWindowCornerRadius {
            hostingView.layer?.cornerRadius = radius
            hostingView.layer?.cornerCurve = .continuous
            hostingView.layer?.masksToBounds = true
        }
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.delegate = windowDelegate
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }

    private func complete() {
        onComplete?()
        close()
    }

    private func updateWindowHeight(_ contentHeight: CGFloat) {
        guard let window, contentHeight > 0 else { return }
        let targetHeight = ceil(contentHeight)
        let currentFrame = window.frame
        let currentContentHeight = window.contentRect(forFrameRect: currentFrame).height
        guard abs(currentContentHeight - targetHeight) > 0.5 else { return }

        let frameDelta = targetHeight - currentContentHeight
        var newFrame = currentFrame
        newFrame.size.height += frameDelta
        // Keep the window visually anchored at its top edge as it grows/shrinks.
        newFrame.origin.y -= frameDelta
        window.setFrame(newFrame, display: true, animate: window.isVisible)
    }
}
