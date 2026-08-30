import ClipKittyCore
import ClipKittyRust
import ClipKittyStore
import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Makes this view a window-wide drop target that saves dropped content
    /// (images, URLs, text) as new clips — the drag-and-drop counterpart of
    /// the + menu's paste/import paths.
    func addClipDropTarget() -> some View {
        modifier(AddClipDropTarget())
    }
}

/// Accepts drags from other apps anywhere over the window and adds them to
/// the history, with the same toast/haptic/refresh choreography as the other
/// add paths. ClipKitty's own card drags are recognized (via
/// `DragItemProvider.internalDragMarker`) and declined so dragging a clip
/// around the app never duplicates it. In practice cross-app drags exist on
/// iPad today, but nothing here is idiom-gated — an iPhone that can source a
/// drag gets the same behavior for free.
private struct AddClipDropTarget: ViewModifier {
    @Environment(AppContainer.self) private var container
    @Environment(AppState.self) private var appState
    @Environment(HapticsClient.self) private var haptics
    @State private var ingestRequestID: UUID?
    @State private var ingestTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onDrop(
                of: DroppedClipReader.acceptedTypes,
                delegate: ClipDropDelegate(
                    ingest: { providers in
                        startIngest(providers)
                    }
                )
            )
            .onDisappear {
                cancelIngestTasks()
            }
    }

    /// Keeps the accepted drop owned by the foreground store session. A second
    /// drop in any app window is declined until the first task has completely
    /// finished, avoiding independent aggregate-size batches materializing at
    /// once.
    @MainActor
    private func startIngest(_ providers: [NSItemProvider]) -> Bool {
        let providers = DroppedClipPolicy.standard.boundedProviders(providers)
        guard !providers.isEmpty else { return false }
        let requestID = UUID()
        guard DroppedClipIngestAdmission.shared.admit(requestID: requestID) else {
            return false
        }
        let task = Task { @MainActor in
            defer { finishIngest(requestID: requestID) }
            guard isCurrentIngest(requestID: requestID) else { return }
            await ingest(providers, requestID: requestID)
        }
        ingestRequestID = requestID
        ingestTask = task
        guard appState.registerForegroundTask(id: requestID, task: task) else {
            cancelIngest(requestID: requestID)
            return false
        }
        return true
    }

    /// Saves every readable payload in the drop, then reports once for the
    /// whole batch — one "Added" toast, not a volley.
    @MainActor
    private func ingest(_ providers: [NSItemProvider], requestID: UUID) async {
        var committedAny = false
        var failedAny = false
        var budget = DroppedClipBatchBudget()
        defer {
            if committedAny {
                // A repository write can commit immediately before terminal
                // cancellation becomes observable. Always invalidate the feed
                // for committed data; AppState safely defers browser work when
                // the outgoing session is already suspended.
                appState.refreshFeed()
            }
        }

        for provider in providers {
            guard isCurrentIngest(requestID: requestID) else { return }
            guard budget.remainingByteCount > 0 else {
                failedAny = true
                break
            }
            guard let payload = await DroppedClipReader.load(
                from: provider,
                policy: budget.nextPayloadPolicy
            ) else {
                guard isCurrentIngest(requestID: requestID) else { return }
                failedAny = true
                continue
            }
            guard isCurrentIngest(requestID: requestID) else { return }
            guard budget.admit(payload) else {
                failedAny = true
                break
            }

            let result: Result<String, ClipboardError>
            switch payload {
            case let .image(data, analysis):
                result = await appState.saveImage(
                    imageData: data,
                    thumbnail: analysis.thumbnail,
                    sourceApp: "Drop",
                    sourceAppBundleId: nil,
                    isAnimated: analysis.isAnimated
                )
            case let .url(url):
                result = await container.repository.saveText(
                    text: url.absoluteString,
                    sourceApp: "Drop",
                    sourceAppBundleId: nil
                )
            case let .text(text):
                result = await container.repository.saveText(
                    text: text,
                    sourceApp: "Drop",
                    sourceAppBundleId: nil
                )
            }
            if case .success = result {
                // Record the authoritative repository outcome before checking
                // cancellation so an already-committed item is never hidden.
                committedAny = true
            }
            guard isCurrentIngest(requestID: requestID) else { return }

            switch result {
            case .success: break
            case .failure: failedAny = true
            }
        }

        guard isCurrentIngest(requestID: requestID) else { return }
        if committedAny {
            haptics.fire(.success)
            appState.showToast(.addSucceeded)
        } else if failedAny {
            haptics.fire(.destructive)
            appState.showToast(.addFailed(String(localized: "Could not read dropped content")))
        }
    }

    @MainActor
    private func isCurrentIngest(requestID: UUID) -> Bool {
        !Task.isCancelled
            && ingestRequestID == requestID
            && DroppedClipIngestAdmission.shared.owns(requestID: requestID)
    }

    @MainActor
    private func cancelIngest(requestID: UUID) {
        guard ingestRequestID == requestID else { return }
        // Keep the admission leased until the cancelled task's defer runs.
        // A quick reappearance must not start a second batch while a committed
        // repository call from the first one is still unwinding.
        ingestTask?.cancel()
    }

    @MainActor
    private func cancelIngestTasks() {
        guard ingestRequestID != nil else { return }
        ingestTask?.cancel()
    }

    @MainActor
    private func finishIngest(requestID: UUID) {
        appState.finishForegroundTask(id: requestID)
        _ = DroppedClipIngestAdmission.shared.finish(requestID: requestID)
        guard ingestRequestID == requestID else { return }
        ingestRequestID = nil
        ingestTask = nil
    }
}

/// Session gatekeeper for the drop target: ClipKitty's own card drags are
/// rejected at validation time — no dead drop — because the clip already
/// lives in the store; everything else is handed to `ingest` on release.
private struct ClipDropDelegate: DropDelegate {
    let ingest: ([NSItemProvider]) -> Bool

    /// Providers worth saving: conforming to an accepted type and not marked
    /// as one of our own card drags. Type metadata (unlike item data) is
    /// readable while the drag merely hovers, so validation can filter on it.
    private func externalProviders(_ info: DropInfo) -> [NSItemProvider] {
        info.itemProviders(for: DroppedClipReader.acceptedTypes)
            .filter { !DroppedClipReader.isInternalDrag($0) }
    }

    func validateDrop(info: DropInfo) -> Bool {
        !externalProviders(info).isEmpty
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = externalProviders(info)
        guard !providers.isEmpty else { return false }
        return ingest(providers)
    }
}
