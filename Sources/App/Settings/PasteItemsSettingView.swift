import SwiftUI
import AppKit

#if !APP_STORE

/// Selection for paste item behavior
enum PasteItemsSelection: String, CaseIterable {
    case toActiveApp
    case toClipboard
}

/// A settings view for configuring paste behavior with a radio-button style picker.
struct PasteItemsSettingView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var showingPermissionSheet = false
    /// Track permission state locally for reactive updates (bridged from @Observable monitor)
    @State private var hasPermission: Bool = AppSettings.shared.accessibilityPermissionMonitor.isGranted

    /// Binding that maps autoPasteEnabled to our selection enum
    private var selection: Binding<PasteItemsSelection> {
        Binding(
            get: { settings.autoPasteEnabled ? .toActiveApp : .toClipboard },
            set: { newValue in
                settings.autoPasteEnabled = (newValue == .toActiveApp)
            }
        )
    }

    /// Whether to show the permission prompt (user selected active app but no permission)
    private var showPermissionPrompt: Bool {
        settings.autoPasteEnabled && !hasPermission
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Radio buttons and text
            VStack(alignment: .leading, spacing: 6) {
                // "To active app" option
                PasteItemsOptionRow(
                    isSelected: selection.wrappedValue == .toActiveApp,
                    title: String(localized: "To active app"),
                    description: String(localized: "Paste selected items directly to the application you are currently using."),
                    onSelect: { selection.wrappedValue = .toActiveApp }
                )

                // Permission prompt (nested under "To active app")
                if showPermissionPrompt {
                    AccessibilityPermissionPromptRow {
                        showingPermissionSheet = true
                    }
                    .padding(.leading, 22)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // "To clipboard" option
                PasteItemsOptionRow(
                    isSelected: selection.wrappedValue == .toClipboard,
                    title: String(localized: "To clipboard"),
                    description: String(localized: "Copy selected items to the system clipboard to paste manually later."),
                    onSelect: { selection.wrappedValue = .toClipboard }
                )
            }

            Spacer()

            // Single illustration that changes based on selection
            PasteIllustrationView(type: selection.wrappedValue == .toActiveApp ? .toActiveApp : .toClipboard)
                .frame(width: 80, height: 56)
        }
        .animation(.easeInOut(duration: 0.2), value: showPermissionPrompt)
        .sheet(isPresented: $showingPermissionSheet) {
            AccessibilityPermissionSheet(isPresented: $showingPermissionSheet)
        }
        .onAppear {
            // Sync initial state
            hasPermission = settings.accessibilityPermissionMonitor.isGranted
            // Start monitoring when the view appears (if needed)
            if !hasPermission {
                settings.accessibilityPermissionMonitor.start()
            }
        }
        .onDisappear {
            // Stop monitoring when view disappears
            settings.accessibilityPermissionMonitor.stop()
        }
        .task {
            // Poll permission state to update UI reactively
            // This bridges the @Observable monitor to SwiftUI state
            let monitor = settings.accessibilityPermissionMonitor
            while !Task.isCancelled {
                let granted = monitor.isGranted
                if granted != hasPermission {
                    hasPermission = granted
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

/// Illustration type for paste options
enum PasteIllustration {
    case toActiveApp
    case toClipboard
}

/// A single option row in the paste items picker
private struct PasteItemsOptionRow: View {
    let isSelected: Bool
    let title: String
    let description: String
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 8) {
                // Radio button
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.accentColor : Color.clear)
                        .frame(width: 14, height: 14)
                    Circle()
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                    if isSelected {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 5, height: 5)
                    }
                }
                .padding(.top, 3)

                // Text content
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)

                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Illustration showing the paste mode visually
private struct PasteIllustrationView: View {
    let type: PasteIllustration

    var body: some View {
        switch type {
        case .toActiveApp:
            // App window with cursor
            ZStack {
                // Background (app window representation)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )

                // Window chrome dots
                HStack(spacing: 3) {
                    Circle().fill(Color.red.opacity(0.6)).frame(width: 5, height: 5)
                    Circle().fill(Color.yellow.opacity(0.6)).frame(width: 5, height: 5)
                    Circle().fill(Color.green.opacity(0.6)).frame(width: 5, height: 5)
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                // Content area with three lines of text
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: 4)
                        .padding(.trailing, 12)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 4)
                        .padding(.trailing, 24)
                }
                .padding(.horizontal, 8)
                .padding(.top, 11)
                .padding(.bottom, 8)

            }

        case .toClipboard:
            // App window with "Copied" toast overlay and cursor (no text lines)
            ZStack {
                // Background (app window representation)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )

                // Window chrome dots
                HStack(spacing: 3) {
                    Circle().fill(Color.red.opacity(0.6)).frame(width: 5, height: 5)
                    Circle().fill(Color.yellow.opacity(0.6)).frame(width: 5, height: 5)
                    Circle().fill(Color.green.opacity(0.6)).frame(width: 5, height: 5)
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                // Text I-beam cursor (custom drawn)
                IBeamCursor()
                    .frame(width: 4, height: 8)
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 8)
                    .padding(.top, 16)

                // "Copied" toast at bottom center
                CopiedToastIllustration()
                    .offset(y: 18)
            }
        }
    }
}

/// I-beam text cursor shape
private struct IBeamCursor: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        let stemWidth: CGFloat = 1
        let serifWidth = width * 0.8
        let serifHeight: CGFloat = 1.5

        // Top serif
        path.addRoundedRect(
            in: CGRect(x: (width - serifWidth) / 2, y: 0, width: serifWidth, height: serifHeight),
            cornerSize: CGSize(width: 0.5, height: 0.5)
        )
        // Vertical stem
        path.addRect(CGRect(x: (width - stemWidth) / 2, y: serifHeight, width: stemWidth, height: height - 2 * serifHeight))
        // Bottom serif
        path.addRoundedRect(
            in: CGRect(x: (width - serifWidth) / 2, y: height - serifHeight, width: serifWidth, height: serifHeight),
            cornerSize: CGSize(width: 0.5, height: 0.5)
        )

        return path
    }
}

/// "Copied" toast style illustration for clipboard mode
private struct CopiedToastIllustration: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(.green)
            Text(String(localized: "Copied"))
                .font(.system(size: 7, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
        )
        .overlay(
            Capsule()
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

/// Inline prompt to enable accessibility access
struct AccessibilityPermissionPromptRow: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                // Warning indicator
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.red)

                Text(String(localized: "Enable accessibility access"))
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.08))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    Form {
        Section("Paste Items") {
            PasteItemsSettingView()
        }
    }
    .formStyle(.grouped)
    .frame(width: 450, height: 300)
}

#endif
