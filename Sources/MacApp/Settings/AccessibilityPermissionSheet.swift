import AppKit
import ClipKittyMacPlatform
import SwiftUI

/// A sheet explaining what accessibility permission enables and how to grant it.
/// Auto-dismisses when permission is detected as granted.
struct AccessibilityPermissionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var permissionMonitor = AppRuntimeState.shared.accessibilityPermissionMonitor
    let reason: AutomaticPasteUnavailableReason

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "accessibility")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)

                switch reason {
                case .permissionNotGranted:
                    Text(String(localized: "Enable Accessibility Access"))
                        .font(.title2)
                        .fontWeight(.semibold)
                case .permissionRequiresRepair:
                    Text(String(localized: "Repair Accessibility Access"))
                        .font(.title2)
                        .fontWeight(.semibold)
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            // Explanation
            VStack(alignment: .leading, spacing: 16) {
                switch reason {
                case .permissionNotGranted:
                    Text(String(localized: "ClipKitty needs accessibility permission to paste items directly into apps by simulating keyboard shortcuts (⌘V)."))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .permissionRequiresRepair:
                    Text(String(localized: "macOS lists ClipKitty as allowed, but is blocking automatic paste. Remove ClipKitty from Accessibility, then add it again to repair access."))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Steps
                VStack(alignment: .leading, spacing: 12) {
                    PermissionStepRow(
                        number: 1,
                        text: String(localized: "Click \"Open System Settings\" below")
                    )
                    switch reason {
                    case .permissionNotGranted:
                        PermissionStepRow(
                            number: 2,
                            text: String(localized: "Find ClipKitty in the list")
                        )
                    case .permissionRequiresRepair:
                        PermissionStepRow(
                            number: 2,
                            text: String(localized: "Remove ClipKitty using the minus button, then add it again")
                        )
                    }
                    PermissionStepRow(
                        number: 3,
                        text: String(localized: "Toggle the switch to enable access")
                    )
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            // Footer note
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                Text(String(localized: "ClipKitty will detect when permission is granted."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 16)

            // Buttons
            HStack(spacing: 12) {
                Button(action: openSystemSettings) {
                    HStack(spacing: 4) {
                        Text(String(localized: "Open System Settings"))
                        Image(systemName: "arrow.up.forward.square")
                            .font(.subheadline)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)

                Button(String(localized: "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(width: 380, height: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: permissionMonitor.status) { _, status in
            switch status {
            case .granted:
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    dismiss()
                }
            case .notGranted, .requiresRepair:
                break
            }
        }
    }

    private func openSystemSettings() {
        // Request permission - this triggers the macOS permission dialog
        permissionMonitor.requestPermission()
        // Also open System Settings so user can toggle if needed
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

/// A single step in the permission instructions
private struct PermissionStepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.blue))

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }
}

#Preview {
    AccessibilityPermissionSheet(reason: .permissionRequiresRepair)
}
