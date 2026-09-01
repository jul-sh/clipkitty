import SwiftUI

/// First-launch onboarding: a short sequence of full-screen pages introducing
/// ClipKitty, offering iCloud sync, showing how to save from other apps, and
/// walking the user through the paste permission Auto-Add depends on.
struct OnboardingScreen: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppState.self) private var appState
    @Environment(iOSSettingsStore.self) private var settings
    #if ENABLE_ICLOUD_SYNC
        /// Optional on purpose: the coordinator leaves the environment while
        /// the app suspends but the last session's tree keeps rendering (see
        /// `RootView.syncCoordinator`).
        @Environment(iOSSyncCoordinator.self) private var syncCoordinator: iOSSyncCoordinator?
    #endif

    let onComplete: () -> Void

    @State private var flowState: OnboardingFlowState = .page(.welcome)
    @State private var probeTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            page(for: flowState.visiblePage)
                .id(flowState.visiblePage)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))

            if let previous = flowState.visiblePage.previous {
                backButton { goBack(to: previous) }
            }
        }
        .animation(.snappy, value: flowState.visiblePage)
        .sheet(isPresented: isExplainingPasteAccess) {
            PasteAccessHowToSheet(onDismiss: finishPasteAccessPage)
                // Sized to its own content so the instructions sit as a card
                // over the page rather than a mostly-empty full-height sheet.
                .presentationDetents([.height(520)])
                .presentationDragIndicator(.hidden)
                // The sheet's only exits are its close button and Open
                // Settings, both of which end onboarding, so an interactive
                // dismiss must do the same rather than stranding the page.
                .interactiveDismissDisabled()
        }
        .onDisappear {
            probeTask?.cancel()
            probeTask = nil
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private func page(for page: OnboardingPage) -> some View {
        switch page {
        case .welcome:
            OnboardingPageScaffold(
                title: String(localized: "A Better Way to Copy and Paste"),
                message: String(
                    localized: "ClipKitty is a time machine for your clipboard that lets you instantly find anything you’ve ever copied and use it whenever you need it again."
                ),
                heroStyle: .inline
            ) {
                OnboardingAppIcon()
            } actions: {
                OnboardingPrimaryButton(title: String(localized: "Get Started")) {
                    advance(from: .welcome)
                }
                .accessibilityIdentifier("onboarding.getStartedButton")
            }

        case .sync:
            OnboardingPageScaffold(
                title: String(localized: "Access on Any Device"),
                message: String(
                    localized: "Keep and organize everything you copy across your iPhone, iPad, and Mac."
                ),
                heroStyle: .fullBleed
            ) {
                OnboardingSyncHero()
            } actions: {
                OnboardingPrimaryButton(title: String(localized: "Continue")) {
                    enableSyncIfAvailable()
                    advance(from: .sync)
                }
                .accessibilityIdentifier("onboarding.syncContinueButton")

                OnboardingSecondaryButton(
                    title: String(localized: "Secured with iCloud Sync"),
                    systemImage: "checkmark.icloud"
                )
            }

        case .share:
            OnboardingPageScaffold(
                title: String(localized: "Copy from Any App"),
                message: String(
                    localized: "Save links, text, images, and any other content by sharing it to ClipKitty from the share menu."
                ),
                heroStyle: .fullBleed
            ) {
                OnboardingShareHero()
            } actions: {
                OnboardingPrimaryButton(title: String(localized: "Continue")) {
                    advance(from: .share)
                }
                .accessibilityIdentifier("onboarding.shareContinueButton")
            }

        case .pasteAccess:
            OnboardingPageScaffold(
                title: String(localized: "Save from Your Clipboard"),
                message: String(
                    localized: "Allow ClipKitty to read your clipboard so everything you copy is saved automatically, without asking every time."
                ),
                heroStyle: .fullBleed
            ) {
                OnboardingPasteAccessHero()
            } actions: {
                OnboardingPrimaryButton(title: String(localized: "Allow Paste from Other Apps")) {
                    beginPasteAccessProbe()
                }
                .disabled(isProbingPasteAccess)
                .accessibilityIdentifier("onboarding.allowPasteButton")

                OnboardingSecondaryButton(
                    title: String(localized: "Enable Later in Settings"),
                    action: onComplete
                )
                .accessibilityIdentifier("onboarding.enableLaterButton")
            }
        }
    }

    private func backButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(.regularMaterial, in: .circle)
        }
        .buttonStyle(.plain)
        .padding(.leading, 20)
        .padding(.top, 8)
        .accessibilityLabel(String(localized: "Back"))
        .accessibilityIdentifier("onboarding.backButton")
    }

    // MARK: - Navigation

    private func advance(from page: OnboardingPage) {
        switch page.next {
        case let .some(next):
            flowState = .page(next)
        case .none:
            onComplete()
        }
    }

    private func goBack(to page: OnboardingPage) {
        // Leaving the permission page abandons any in-flight probe; the system
        // alert it raised is answered against a page the user has left.
        probeTask?.cancel()
        probeTask = nil
        flowState = .page(page)
    }

    private func enableSyncIfAvailable() {
        #if ENABLE_ICLOUD_SYNC
            guard !settings.syncEnabled else { return }
            settings.syncEnabled = true
            syncCoordinator?.setSyncEnabled(true)
        #endif
    }

    // MARK: - Paste access

    /// Reads the clipboard so iOS raises its paste-consent alert, then shows
    /// the how-to sheet.
    ///
    /// The sheet follows either answer to that alert on purpose. "Allow Paste"
    /// there authorizes exactly one read; the persistent grant Auto-Add needs
    /// lives in Settings, so the instructions are what actually completes this
    /// page. The probe still earns its place: it puts the real system alert in
    /// front of the user with the app's own explanation still on screen.
    private func beginPasteAccessProbe() {
        guard case .page(.pasteAccess) = flowState else { return }
        flowState = .probingPasteAccess

        let clipboardService = container.clipboardService
        let requestID = UUID()
        let task = Task { @MainActor in
            defer { appState.finishForegroundTask(id: requestID) }
            _ = await clipboardService.readCurrentClipboardForAutomaticIngest()
            guard !Task.isCancelled, case .probingPasteAccess = flowState else { return }
            flowState = .explainingPasteAccess
        }
        probeTask = task
        // The read is a foreground-only clipboard touch: terminal suspension
        // must cancel and join it before the session's store is sealed. A
        // session that no longer accepts work cancels the task on registration,
        // which leaves the page on its instructions rather than stuck probing.
        guard appState.registerForegroundTask(id: requestID, task: task) else {
            probeTask = nil
            flowState = .explainingPasteAccess
            return
        }
    }

    /// Auto-Add is switched on as the user leaves this page. Whether the
    /// persistent grant was actually made is not observable to the app: with
    /// it, ingest runs silently; without it, iOS prompts on each read and the
    /// monitor's `temporarilyUnavailable` path retries rather than
    /// permanently suppressing the clip.
    private func finishPasteAccessPage() {
        settings.autoAddFromClipboard = true
        onComplete()
    }

    private var isExplainingPasteAccess: Binding<Bool> {
        Binding(
            get: {
                if case .explainingPasteAccess = flowState { return true }
                return false
            },
            set: { isPresented in
                guard !isPresented, case .explainingPasteAccess = flowState else { return }
                finishPasteAccessPage()
            }
        )
    }

    private var isProbingPasteAccess: Bool {
        if case .probingPasteAccess = flowState { return true }
        return false
    }
}
