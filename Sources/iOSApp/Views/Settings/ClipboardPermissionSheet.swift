import SwiftUI
import UIKit

enum ClipboardPermissionStatus: Equatable {
    case unknown
    case verifying
    case checked(ClipboardAccessVerification)
}

struct ClipboardPermissionPromptRow: View {
    let status: ClipboardPermissionStatus
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                icon
                    .frame(width: 24, height: 24)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(content.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(content.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var icon: some View {
        switch status {
        case .verifying:
            ProgressView()
                .controlSize(.small)
        case .unknown, .checked:
            Image(systemName: content.iconSystemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(content.tint)
        }
    }

    private var content: ClipboardPermissionRowContent {
        switch status {
        case .unknown:
            return .init(
                iconSystemName: "exclamationmark.triangle.fill",
                tint: .orange,
                title: String(localized: "Verify Clipboard Access"),
                message: String(localized: "Allow Paste from Other Apps in Settings so Auto-Add can read copied items.")
            )
        case .verifying:
            return .init(
                iconSystemName: "arrow.triangle.2.circlepath",
                tint: .secondary,
                title: String(localized: "Checking Clipboard Access"),
                message: String(localized: "ClipKitty is checking whether iOS allows clipboard reads.")
            )
        case .checked(.granted):
            return .init(
                iconSystemName: "checkmark.circle.fill",
                tint: .green,
                title: String(localized: "Clipboard Access Verified"),
                message: String(localized: "Auto-Add can read clipboard items when ClipKitty opens.")
            )
        case .checked(.needsClipboardItem):
            return .init(
                iconSystemName: "doc.on.clipboard",
                tint: .orange,
                title: String(localized: "Copy an Item to Verify"),
                message: String(localized: "Copy text, a link, or an image from another app, then check again.")
            )
        case .checked(.needsSettingsChange):
            return .init(
                iconSystemName: "exclamationmark.triangle.fill",
                tint: .orange,
                title: String(localized: "Clipboard Permission Needed"),
                message: String(localized: "Set Paste from Other Apps to Allow in the iOS Settings app.")
            )
        }
    }
}

struct ClipboardPermissionVerifiedRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.green)
                .frame(width: 24, height: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Clipboard Access Verified"))
                    .font(.subheadline.weight(.semibold))

                Text(String(localized: "Auto-Add can read clipboard items when ClipKitty opens."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ClipboardPermissionSheet: View {
    @Binding var isPresented: Bool
    @Binding var status: ClipboardPermissionStatus

    let clipboardService: iOSClipboardService

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    explanation
                    instructions
                    statusMessage
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 20)
            }

            Divider()

            buttons
                .padding(24)
        }
        .presentationDetents([.medium, .large])
        .task {
            await verifyClipboardAccess()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                Task { await verifyClipboardAccess() }
            case .inactive, .background:
                break
            @unknown default:
                break
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 40))
                .foregroundStyle(.blue)

            Text(String(localized: "Enable Clipboard Access"))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
        }
    }

    private var explanation: some View {
        Text(String(localized: "ClipKitty needs permission to paste from other apps so it can automatically save the current clipboard when you open the app."))
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            ClipboardPermissionStepRow(
                number: 1,
                text: String(localized: "Tap \"Open App Settings\" below")
            )
            ClipboardPermissionStepRow(
                number: 2,
                text: String(localized: "Open \"Paste from Other Apps\"")
            )
            ClipboardPermissionStepRow(
                number: 3,
                text: String(localized: "Choose \"Allow\"")
            )
            ClipboardPermissionStepRow(
                number: 4,
                text: String(localized: "Return to ClipKitty to verify access")
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusMessage: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(statusContent.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(statusContent.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .verifying:
            ProgressView()
                .controlSize(.small)
        case .unknown, .checked:
            Image(systemName: statusContent.iconSystemName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(statusContent.tint)
        }
    }

    private var buttons: some View {
        VStack(spacing: 12) {
            Button(action: openAppSettings) {
                Label(String(localized: "Open App Settings"), systemImage: "arrow.up.forward.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                Task { await verifyClipboardAccess() }
            } label: {
                Label(String(localized: "Check Again"), systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            switch status {
            case .checked(.granted):
                Button(String(localized: "Done")) {
                    isPresented = false
                }
                .buttonStyle(.plain)
            case .unknown, .verifying, .checked(.needsClipboardItem), .checked(.needsSettingsChange):
                Button(String(localized: "Cancel")) {
                    isPresented = false
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var statusContent: ClipboardPermissionRowContent {
        switch status {
        case .unknown:
            return .init(
                iconSystemName: "checkmark.circle",
                tint: .secondary,
                title: String(localized: "Ready to check"),
                message: String(localized: "ClipKitty will verify clipboard access before Auto-Add reads copied items.")
            )
        case .verifying:
            return .init(
                iconSystemName: "arrow.triangle.2.circlepath",
                tint: .secondary,
                title: String(localized: "Checking access"),
                message: String(localized: "If iOS asks for paste permission, choose Allow Paste.")
            )
        case .checked(.granted):
            return .init(
                iconSystemName: "checkmark.circle.fill",
                tint: .green,
                title: String(localized: "Clipboard access is enabled"),
                message: String(localized: "Auto-Add from Clipboard is ready.")
            )
        case .checked(.needsClipboardItem):
            return .init(
                iconSystemName: "doc.on.clipboard",
                tint: .orange,
                title: String(localized: "Clipboard item needed"),
                message: String(localized: "Copy text, a link, or an image from another app, then return to ClipKitty and check again.")
            )
        case .checked(.needsSettingsChange):
            return .init(
                iconSystemName: "exclamationmark.triangle.fill",
                tint: .orange,
                title: String(localized: "Permission is not granted yet"),
                message: String(localized: "Open app settings and set Paste from Other Apps to Allow.")
            )
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    private func verifyClipboardAccess() async {
        status = .verifying
        await Task.yield()

        let result = clipboardService.verifyAutoAddClipboardAccess()
        withAnimation {
            status = .checked(result)
        }

        if case .granted = result {
            try? await Task.sleep(for: .milliseconds(500))
            isPresented = false
        }
    }
}

private struct ClipboardPermissionStepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.blue))

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ClipboardPermissionRowContent {
    let iconSystemName: String
    let tint: Color
    let title: String
    let message: String
}
