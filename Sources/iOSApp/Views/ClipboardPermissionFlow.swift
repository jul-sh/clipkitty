import Combine
import SwiftUI
import UIKit

// The "Paste from Other Apps" permission nudge: a banner card at the top of
// the home feed that opens a two-sheet flow walking the user through granting
// ClipKitty standing clipboard access in the Settings app. There is no API to
// query or request that permission directly, so the flow can only explain the
// steps and deep-link into Settings; visibility is governed by
// `iOSSettingsStore.permissionHintDismissed`.

/// Feed banner inviting the user to allow clipboard access. Tapping the card
/// opens `SaveAutomaticallySheet`; the ✕ hides the card for good.
///
/// The open and dismiss buttons are siblings, not an overlay: stacked, the
/// card's tap surface sat above the ✕ and swallowed its taps.
struct ClipboardPermissionCard: View {
    @Environment(iOSSettingsStore.self) private var settings
    let onOpenFlow: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Button(action: onOpenFlow) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(String(localized: "Save Automatically"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        Text(String(localized: "Allow ClipKitty to read the clipboard without asking every time."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: 0)
                }
                .padding([.top, .leading, .bottom], 14)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.permissionCard")

            Button {
                withAnimation(.bouncy) {
                    settings.permissionHintDismissed = true
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Dismiss"))
            .accessibilityIdentifier("home.permissionCardDismiss")
        }
        .background(
            Color(.tertiarySystemFill),
            in: RoundedRectangle(cornerRadius: CardSurface.cornerRadius, style: .continuous)
        )
    }
}

/// First sheet: explains why standing clipboard access helps, headed by a
/// mock of the system paste prompt the permission makes go away.
///
/// `resumeInDoneState` re-opens the stacked how-to sheet in its "Done"
/// configuration. Heading to the Settings app suspends ClipKitty and every
/// sheet is gone by the time the user comes back (suspension tears down the
/// session and rebootstraps with fresh view state), so the feed re-presents
/// the flow this way to land the user back on the finishing step.
struct SaveAutomaticallySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainer.self) private var container
    @Environment(iOSSettingsStore.self) private var settings

    let resumeInDoneState: Bool
    @State private var showHowTo: Bool

    init(resumeInDoneState: Bool = false) {
        self.resumeInDoneState = resumeInDoneState
        _showHowTo = State(initialValue: resumeInDoneState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SystemPastePromptIllustration()

            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "Save Automatically"))
                    .font(.title2.bold())
                Text(String(localized: "Allow ClipKitty to save content from your clipboard automatically so you don’t get asked every time it needs access."))
                    .foregroundStyle(.secondary)
            }
            .padding(24)

            Spacer(minLength: 16)

            VStack(spacing: 12) {
                Button {
                    requestPasteAccessOnce()
                    showHowTo = true
                } label: {
                    Text(String(localized: "Allow Paste from Other Apps"))
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("permissionFlow.allowButton")

                Button {
                    settings.permissionFlowResumePending = false
                    dismiss()
                } label: {
                    Text(String(localized: "Enable Later in Settings"))
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("permissionFlow.laterButton")
            }
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .presentationDragIndicator(.hidden)
        .sheet(isPresented: $showHowTo) {
            HowToAllowPasteSheet(startInDoneState: resumeInDoneState) {
                settings.permissionFlowResumePending = false
                withAnimation(.bouncy) {
                    settings.permissionHintDismissed = true
                }
                // Dismissing this sheet takes the stacked how-to sheet with it.
                dismiss()
            }
        }
    }

    /// One real pasteboard read so iOS registers ClipKitty as an app that
    /// pastes: the "Paste from Other Apps" row only exists on the app's
    /// Settings page after at least one actual paste-access request, and the
    /// app-settings deep link only lands on ClipKitty's page once the app has
    /// a page to land on. If the permission is still "Ask" the system prompt
    /// appears over this sheet — the same beat as Paste's flow — and the
    /// read's value is discarded either way.
    private func requestPasteAccessOnce() {
        let clipboardService = container.clipboardService
        Task { @MainActor in
            _ = await clipboardService.readCurrentClipboardForAutomaticIngest()
        }
    }
}

/// Second sheet, stacked over the first: numbered steps plus an auto-advancing
/// carousel mocking the two Settings screens the user is about to see. Once
/// they head to Settings, "Done" takes over as the primary action.
struct HowToAllowPasteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(iOSSettingsStore.self) private var settings

    /// Called when the user taps "Done" after visiting Settings; the parent
    /// tears down the whole flow.
    let onFinished: () -> Void

    @State private var pageIndex: Int
    @State private var didOpenSettings: Bool

    init(startInDoneState: Bool = false, onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
        _didOpenSettings = State(initialValue: startInDoneState)
        // Returning from Settings means step 1 is behind the user; open on
        // the "Select Allow" page.
        _pageIndex = State(initialValue: startInDoneState ? 1 : 0)
    }

    /// Matches the pace of Paste's carousel: slow enough to read a step,
    /// fast enough to preview both before the user commits.
    private let pageTimer = Timer.publish(every: 3.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                Text(String(localized: "How to Allow Paste from Other Apps?"))
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    settings.permissionFlowResumePending = false
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color(.tertiarySystemFill), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Close"))
                .accessibilityIdentifier("permissionFlow.closeButton")
            }

            VStack(alignment: .leading, spacing: 14) {
                stepRow(
                    number: 1,
                    text: String(localized: "Open Settings and tap “Paste from Other Apps”"),
                    isActive: pageIndex == 0
                )
                stepRow(
                    number: 2,
                    text: String(localized: "Select “Allow”"),
                    isActive: pageIndex == 1
                )
            }

            TabView(selection: $pageIndex) {
                SettingsListIllustration().tag(0)
                AllowPickerIllustration().tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onReceive(pageTimer) { _ in
                withAnimation {
                    pageIndex = (pageIndex + 1) % 2
                }
            }

            HStack(spacing: 8) {
                ForEach(0 ..< 2) { index in
                    Circle()
                        .fill(index == pageIndex ? Color.primary : Color(.systemFill))
                        .frame(width: 7, height: 7)
                }
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 12) {
                if didOpenSettings {
                    Button(action: onFinished) {
                        Text(String(localized: "Done"))
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("permissionFlow.doneButton")

                    Button(action: openSystemSettings) {
                        Text(String(localized: "Open Settings"))
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("permissionFlow.openSettingsButton")
                } else {
                    Button(action: openSystemSettings) {
                        Text(String(localized: "Open Settings"))
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("permissionFlow.openSettingsButton")
                }
            }
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .padding(20)
    }

    private func stepRow(number: Int, text: String, isActive: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(isActive ? AnyShapeStyle(Color(.systemBackground)) : AnyShapeStyle(.secondary))
                .frame(width: 22, height: 22)
                .background(isActive ? Color.primary : Color(.systemFill), in: .circle)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.default, value: isActive)
    }

    /// The permission lives in the Settings app, so the best we can do is
    /// land the user on ClipKitty's page there. Flip to the "Done" layout
    /// right away: the app resigns active immediately, and the new buttons
    /// are what should greet the user when they come back. The persisted
    /// resume flag covers the usual case where the trip to Settings suspends
    /// ClipKitty and this sheet is gone on return — the feed re-presents the
    /// flow straight into this "Done" configuration.
    private func openSystemSettings() {
        didOpenSettings = true
        settings.permissionFlowResumePending = true
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

// MARK: - Illustrations

//
// Hand-drawn mocks instead of bundled screenshots: they follow Dynamic Type,
// light/dark mode, and localization for free, and skeleton bars stand in for
// the unrelated system rows so no fake system copy needs translating.

/// The system "would like to paste from any app" prompt this flow makes
/// unnecessary. Decorative only.
private struct SystemPastePromptIllustration: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemGroupedBackground), Color(.secondarySystemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 18) {
                VStack(spacing: 4) {
                    Text(String(localized: "“ClipKitty” would like to paste from any app"))
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text(String(localized: "Do you want to allow this?"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 10) {
                    Text(String(localized: "Don’t Allow Paste"))
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color(.systemFill), in: .capsule)
                    Text(String(localized: "Allow Paste"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.accentColor, in: .capsule)
                }
            }
            .padding(20)
            .frame(maxWidth: 300)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 26, style: .continuous)
            )
            .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
            .padding(.horizontal, 40)
        }
        .frame(height: 300)
        .accessibilityHidden(true)
    }
}

/// Step 1: ClipKitty's page in the Settings app, skeleton rows above the
/// highlighted "Paste from Other Apps" row.
private struct SettingsListIllustration: View {
    var body: some View {
        SettingsPhoneMock {
            Text(String(localized: "Allow ClipKitty to Access"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)

            VStack(spacing: 0) {
                skeletonRow(accessory: .chevron)
                Divider().padding(.leading, 40)
                skeletonRow(accessory: .chevron)
                Divider().padding(.leading, 40)
                skeletonRow(accessory: .toggle)
                Divider().padding(.leading, 40)
                skeletonRow(accessory: .toggle)
            }
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )

            HStack {
                Text(String(localized: "Paste from Other Apps"))
                    .font(.caption)
                Spacer()
                Text(String(localized: "Ask"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(
                Color.accentColor.opacity(0.18),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .padding(.top, 8)
        }
    }

    private enum Accessory {
        case chevron
        case toggle
    }

    private func skeletonRow(accessory: Accessory) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(.systemFill))
                .frame(width: 20, height: 20)
            Capsule()
                .fill(Color(.systemFill))
                .frame(width: 90, height: 8)
            Spacer()
            switch accessory {
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            case .toggle:
                Capsule()
                    .fill(Color.green)
                    .frame(width: 30, height: 18)
                    .overlay(alignment: .trailing) {
                        Circle()
                            .fill(.white)
                            .frame(width: 15, height: 15)
                            .padding(.trailing, 1.5)
                    }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }
}

/// Step 2: the "Paste from Other Apps" detail screen with "Allow" selected.
private struct AllowPickerIllustration: View {
    var body: some View {
        SettingsPhoneMock {
            Text(String(localized: "Paste from Other Apps"))
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 4)

            VStack(spacing: 0) {
                pickerRow(String(localized: "Ask"), isSelected: false)
                Divider().padding(.leading, 12)
                pickerRow(String(localized: "Deny"), isSelected: false)
                Divider().padding(.leading, 12)
                pickerRow(String(localized: "Allow"), isSelected: true)
            }
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
    }

    private func pickerRow(_ title: String, isSelected: Bool) -> some View {
        HStack {
            Text(title)
                .font(.caption)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear)
    }
}

/// Shared phone-shaped frame for the Settings mocks.
private struct SettingsPhoneMock<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(12)
        .frame(width: 240, alignment: .top)
        .background(
            Color(.systemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.25), lineWidth: 4)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}
