import AppKit
import ClipKittyMacPlatform
import ClipKittyShared
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
    @State private var hotKeyState: HotKeyEditState = .idle
    let onHotKeyChanged: (HotKey) -> Void
    let onComplete: () -> Void

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { newValue in
                if launchAtLogin.setEnabled(newValue) {
                    settings.launchAtLoginEnabled = newValue
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)

            Text("Quick Start")
                .font(.system(size: 22, weight: .bold))

            VStack(spacing: 0) {
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

                Divider()
                    .padding(.horizontal, 16)

                // Hotkey row — clickable to record
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Activation Shortcut")
                            .font(.system(size: 13, weight: .medium))
                        Text("Open your clipboard history anytime")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
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
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .frame(minWidth: 80)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(labelAndBackground.1, in: RoundedRectangle(cornerRadius: 6))
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
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                #if ENABLE_SYNC
                    Divider()
                        .padding(.horizontal, 16)

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
                #endif
            }
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
            .padding(.horizontal, 40)

            HStack(spacing: 6) {
                Image(systemName: "menubar.arrow.up.rectangle")
                    .font(.system(size: 12))
                Text("You can also click the menu bar icon to open ClipKitty.")
                    .font(.system(size: 12))
            }
            .foregroundStyle(.secondary)

            Spacer()

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WelcomeContentView: View {
    @State private var currentPage = 0
    let onHotKeyChanged: (HotKey) -> Void
    let onComplete: () -> Void

    var body: some View {
        Group {
            if currentPage == 0 {
                WelcomePageView(onGetStarted: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentPage = 1
                    }
                })
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            } else {
                QuickStartPageView(
                    onHotKeyChanged: onHotKeyChanged,
                    onComplete: onComplete
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            }
        }
        .frame(width: 500, height: 580)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .controlBackgroundColor),
                    Color(nsColor: .controlBackgroundColor).opacity(0.95),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

// MARK: - Window Controller

@MainActor
final class WelcomeWindowController {
    private(set) var window: NSWindow?
    var onComplete: (() -> Void)?
    var onHotKeyChanged: ((HotKey) -> Void)?
    weak var windowDelegate: NSWindowDelegate?

    func showWindow() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = WelcomeContentView(
            onHotKeyChanged: { [weak self] hotKey in
                self?.onHotKeyChanged?(hotKey)
            },
            onComplete: { [weak self] in
                self?.complete()
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
}
