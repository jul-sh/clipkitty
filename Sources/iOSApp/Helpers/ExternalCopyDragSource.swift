import ClipKittyRust
import SwiftUI
import UIKit

/// The small, UIKit-independent state machine behind an external drag.
///
/// A successful drop operation is not sufficient evidence that the receiving
/// app got the promised data. UIKit ends a `.copy` drag first and calls
/// `dragInteraction(_:sessionDidTransferItems:)` only after the destination
/// has received the representations it requested. Keeping those two signals
/// separate prevents cancelled, forbidden, internal, and failed transfers
/// from triggering destructive follow-up work.
struct ExternalCopyTransferGate: Equatable {
    enum Operation: Equatable {
        case cancel
        case forbidden
        case copy
        case move
        case unknown

        init(_ operation: UIDropOperation) {
            switch operation {
            case .cancel: self = .cancel
            case .forbidden: self = .forbidden
            case .copy: self = .copy
            case .move: self = .move
            @unknown default: self = .unknown
            }
        }
    }

    private struct EndState: Equatable {
        let operation: Operation
        let isOutsideApplicationWindows: Bool
    }

    private var endState: EndState?
    private var didObserveDataTransfer = false

    /// Records the final operation and destination classification. The first
    /// terminal result wins; UIKit delivers one terminal result per session,
    /// and ignoring a conflicting duplicate is safer than changing a retained
    /// item into a deletion candidate.
    mutating func recordEnd(
        operation: Operation,
        isOutsideApplicationWindows: Bool
    ) {
        guard endState == nil, !didObserveDataTransfer else { return }
        endState = EndState(
            operation: operation,
            isOutsideApplicationWindows: isOutsideApplicationWindows
        )
    }

    /// Returns `true` exactly once, and only for a recorded external copy.
    /// Calling this before `recordEnd` permanently fails closed for that
    /// session because the ordering is invalid and deleting would be unsafe.
    mutating func observeDataTransferCompleted() -> Bool {
        guard !didObserveDataTransfer else { return false }
        didObserveDataTransfer = true

        guard let endState else { return false }
        return endState.operation == .copy
            && endState.isOutsideApplicationWindows
    }
}

/// Conservatively decides whether the final drag point is outside ClipKitty.
///
/// UIKit does not expose the destination application's identity to a drag
/// source. Foreground scenes therefore use window geometry; when UIKit has
/// already backgrounded every attached ClipKitty scene, that lifecycle state
/// identifies a full-screen external destination. Every ambiguous state fails
/// closed and leaves the source item untouched.
@MainActor
enum ExternalDragDestinationClassifier {
    static func isOutsideVisibleApplicationWindows(_ session: any UIDragSession) -> Bool {
        let scenes: [ExternalDragSceneSnapshot] = UIApplication.shared.connectedScenes.compactMap {
            scene -> ExternalDragSceneSnapshot? in
            guard let windowScene = scene as? UIWindowScene else { return nil }
            switch windowScene.activationState {
            case .foregroundActive, .foregroundInactive:
                let windows = windowScene.windows
                    .filter { window in
                        !window.isHidden
                            && window.alpha > 0
                            && !window.bounds.isEmpty
                    }
                    .map { window in
                        ExternalDropWindowGeometry(
                            bounds: window.bounds,
                            dropLocation: session.location(in: window)
                        )
                    }
                return ExternalDragSceneSnapshot.foreground(windows: windows)
            case .background:
                return .background
            case .unattached:
                return .unattached
            @unknown default:
                return .unknown
            }
        }

        return ExternalDragScenePolicy.isExternalDestination(scenes)
    }
}

/// The source app often reaches `.background` before UIKit reports the final
/// operation for a full-screen cross-app drop. In that unambiguous state there
/// is no foreground ClipKitty window whose geometry can be queried, but every
/// attached ClipKitty scene being background is itself evidence that the
/// destination is external. Unattached, mixed, unknown, and scene-less states
/// remain fail-closed.
enum ExternalDragSceneSnapshot: Equatable {
    case foreground(windows: [ExternalDropWindowGeometry])
    case background
    case unattached
    case unknown
}

enum ExternalDragScenePolicy {
    static func isExternalDestination(_ scenes: [ExternalDragSceneSnapshot]) -> Bool {
        guard !scenes.isEmpty else { return false }
        guard !scenes.contains(.unattached), !scenes.contains(.unknown) else {
            return false
        }

        let foregroundWindows: [ExternalDropWindowGeometry] = scenes.flatMap { scene in
            switch scene {
            case let .foreground(windows):
                return windows
            case .background, .unattached, .unknown:
                return []
            }
        }
        let hasForegroundScene = scenes.contains { scene in
            if case .foreground = scene { return true }
            return false
        }
        if hasForegroundScene {
            return ExternalDropGeometryClassifier.isOutsideApplicationWindows(
                foregroundWindows
            )
        }

        return scenes.allSatisfy { scene in
            if case .background = scene { return true }
            return false
        }
    }
}

struct ExternalDropWindowGeometry: Equatable {
    let bounds: CGRect
    let dropLocation: CGPoint
}

/// Pure geometry policy used by the UIKit classifier and its regression tests.
enum ExternalDropGeometryClassifier {
    static func isOutsideApplicationWindows(_ windows: [ExternalDropWindowGeometry]) -> Bool {
        guard !windows.isEmpty else { return false }

        var observedUsableLocation = false
        for window in windows {
            let location = window.dropLocation
            guard location.x.isFinite, location.y.isFinite else { continue }
            observedUsableLocation = true
            if window.bounds.contains(window.dropLocation) {
                return false
            }
        }

        return observedUsableLocation
    }
}

/// Bounds how long a completed `.copy` waits for UIKit's separate
/// `sessionDidTransferItems` acknowledgement. Some destinations never send
/// that callback after refusing or abandoning promised data; exact token
/// matching prevents a stale timeout from cancelling a newer state that
/// happens to reuse the same session object identity.
enum ExternalCopyDragSessionExpiryPolicy {
    static let transferAcknowledgementTimeoutNanoseconds: UInt64 = 30_000_000_000

    static func shouldExpire(currentToken: UUID?, scheduledToken: UUID) -> Bool {
        currentToken == scheduledToken
    }
}

/// Thread-safe evidence that an item's promised data was actually delivered.
/// A drag target may ask an `NSItemProvider` for more than one representation.
/// Destructive follow-up fails closed if any requested public representation
/// failed, because UIKit's session-level completion does not identify which
/// item or representation reached the destination.
struct ExternalCopyTransferEvidence: Equatable {
    let itemID: String
    let deletionToken: String
}

final class ExternalCopyDragItemLoadState: @unchecked Sendable {
    private let lock = NSLock()
    private var successfulLoadCount = 0
    private var failedLoadCount = 0
    private var deletionToken: String?
    private var hasInvalidDeletionToken = false

    /// Records the opaque token that describes the exact payload fetched for
    /// this provider. A missing or changed token permanently makes destructive
    /// follow-up ineligible, even if a later retry happens to load data.
    @discardableResult
    func recordDeletionToken(_ candidate: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !candidate.isEmpty, !hasInvalidDeletionToken else {
            hasInvalidDeletionToken = true
            return false
        }
        if let deletionToken, deletionToken != candidate {
            hasInvalidDeletionToken = true
            return false
        }
        deletionToken = candidate
        return true
    }

    func recordRepresentationLoad(succeeded: Bool) {
        lock.lock()
        if succeeded {
            successfulLoadCount += 1
        } else {
            failedLoadCount += 1
        }
        lock.unlock()
    }

    func completedTransferEvidence(itemID: String) -> ExternalCopyTransferEvidence? {
        lock.lock()
        defer { lock.unlock() }
        guard successfulLoadCount > 0,
              failedLoadCount == 0,
              !hasInvalidDeletionToken,
              let deletionToken,
              !deletionToken.isEmpty
        else { return nil }
        return ExternalCopyTransferEvidence(
            itemID: itemID,
            deletionToken: deletionToken
        )
    }
}

struct ExternalCopyDragItem {
    let itemID: String
    let itemProvider: NSItemProvider
    let loadState: ExternalCopyDragItemLoadState
}

struct ExternalCopyDragItemDescriptor: Equatable {
    let itemID: String
    let contentKind: DragItemProvider.ContentKind

    init(itemID: String, contentKind: DragItemProvider.ContentKind) {
        self.itemID = itemID
        self.contentKind = contentKind
    }

    init(itemID: String, icon: ItemIcon) {
        self.init(itemID: itemID, contentKind: DragItemProvider.ContentKind(icon: icon))
    }
}

/// Couples one payload's provider work to its optional app-level background
/// lease. The normal terminal path calls `finish()`. If UIKit instead tears
/// down the interaction without a terminal callback, actor-isolated
/// deinitialization cancels the providers before releasing the lease.
@MainActor
private final class ExternalCopyDragPayloadLifetime {
    private enum State {
        case active
        case followUpReserved
        case cleaning
    }

    private let transferSession: DragItemProvider.TransferSession
    private let followUpCancellation = AppBackgroundTaskCancellation()
    private var externalTransferLease: AppExternalTransferLease?
    private var state = State.active
    private var followUpTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?

    init(
        transferSession: DragItemProvider.TransferSession,
        externalTransferLease: AppExternalTransferLease?
    ) {
        self.transferSession = transferSession
        self.externalTransferLease = externalTransferLease
        externalTransferLease?.installExpirationHandler({ [weak self] in
            // The UIKit reservation is ended by AppExternalTransferLease before
            // this callback returns. The retained AppState latch is released
            // only after this nonblocking cleanup joins provider fetches and an
            // in-flight conditional-delete follow-up.
            self?.expire()
        }, requiresCleanup: true)
    }

    func cancelOutstandingLoads() {
        transferSession.cancel()
    }

    func reserveFollowUp() -> Bool {
        guard case .active = state else { return false }
        state = .followUpReserved
        return true
    }

    func installFollowUp(
        _ task: Task<Void, Never>,
        cancellation: @escaping @Sendable () -> Void
    ) {
        guard case .followUpReserved = state else {
            task.cancel()
            return
        }
        followUpTask = task
        followUpCancellation.install(cancellation)
    }

    func finish() {
        beginCleanup()
    }

    private func expire() {
        followUpCancellation.cancel()
        beginCleanup()
    }

    private func beginCleanup() {
        guard cleanupTask == nil else { return }
        state = .cleaning
        followUpCancellation.cancel()

        // Move all terminal ownership into one task. It retains the lease (and
        // therefore AppState's latch) until cancellation has reached every
        // memoized fetch and any follow-up has returned from its repository
        // mutation. The task does not capture `self`, avoiding a payload/task
        // retain cycle during UIKit teardown.
        let transferSession = transferSession
        let followUpTask = followUpTask
        self.followUpTask = nil
        let followUpCancellation = followUpCancellation
        let lease = externalTransferLease
        externalTransferLease = nil
        cleanupTask = Task { @MainActor in
            await transferSession.cancelAndWait()
            await followUpTask?.value
            followUpCancellation.complete()
            lease?.finish()
        }
    }

    isolated deinit {
        finish()
    }
}

struct ExternalCopyDragPayload {
    let items: [ExternalCopyDragItem]
    private let lifetime: ExternalCopyDragPayloadLifetime?

    /// Compatibility initializer for pre-built providers. It still enforces
    /// the defensive session item cap, but callers that can produce multiple
    /// items should use `init(itemIDs:policy:fetch:)` so the cap is applied
    /// before provider creation and every item shares one transfer budget.
    init(items: [ExternalCopyDragItem]) {
        self.items = Array(items.prefix(DragItemProvider.SessionPolicy.externalDrag.maximumItemCount))
        lifetime = nil
    }

    /// Builds at most 50 providers after stable de-duplication and connects
    /// all of them to one bounded, cancellable transfer session.
    @MainActor
    init(
        itemIDs: [String],
        policy: DragItemProvider.SessionPolicy = .externalDrag,
        externalTransferLease: AppExternalTransferLease? = nil,
        fetchSnapshot: @escaping @Sendable (String) async -> TransferItemSnapshot?
    ) {
        self.init(
            descriptors: itemIDs.map {
                ExternalCopyDragItemDescriptor(itemID: $0, contentKind: .unknown)
            },
            policy: policy,
            externalTransferLease: externalTransferLease,
            fetchSnapshot: fetchSnapshot
        )
    }

    /// Descriptor-based initializer used by production callers. Keeping the
    /// content kind beside each id prevents unrelated public representations
    /// from being advertised or probed by the destination.
    @MainActor
    init(
        descriptors: [ExternalCopyDragItemDescriptor],
        policy: DragItemProvider.SessionPolicy = .externalDrag,
        externalTransferLease: AppExternalTransferLease? = nil,
        fetchSnapshot: @escaping @Sendable (String) async -> TransferItemSnapshot?
    ) {
        let transferSession = DragItemProvider.TransferSession(policy: policy)
        lifetime = ExternalCopyDragPayloadLifetime(
            transferSession: transferSession,
            externalTransferLease: externalTransferLease
        )
        let boundedDescriptors = Self.boundedUniqueDescriptors(
            descriptors,
            maximumCount: policy.maximumItemCount
        )

        items = boundedDescriptors.map { descriptor in
            let loadState = ExternalCopyDragItemLoadState()
            return ExternalCopyDragItem(
                itemID: descriptor.itemID,
                itemProvider: DragItemProvider.make(
                    itemId: descriptor.itemID,
                    contentKind: descriptor.contentKind,
                    transferSession: transferSession,
                    fetch: { itemID in
                        guard let snapshot = await fetchSnapshot(itemID),
                              snapshot.item.itemMetadata.itemId == itemID,
                              loadState.recordDeletionToken(snapshot.deletionToken)
                        else { return nil }
                        return snapshot.item
                    },
                    onRepresentationLoad: { succeeded in
                        loadState.recordRepresentationLoad(succeeded: succeeded)
                    }
                ),
                loadState: loadState
            )
        }
    }

    var itemIDs: [String] {
        items.map(\.itemID)
    }

    var completedTransferEvidence: [ExternalCopyTransferEvidence] {
        items.compactMap { item in
            item.loadState.completedTransferEvidence(itemID: item.itemID)
        }
    }

    @MainActor
    func cancelOutstandingLoads() {
        lifetime?.cancelOutstandingLoads()
    }

    @MainActor
    func reserveFollowUp() -> Bool {
        lifetime?.reserveFollowUp() ?? true
    }

    @MainActor
    func installFollowUp(
        _ task: Task<Void, Never>,
        cancellation: @escaping @Sendable () -> Void
    ) {
        lifetime?.installFollowUp(task, cancellation: cancellation)
    }

    @MainActor
    func finish() {
        lifetime?.finish()
    }

    static func boundedUniqueItemIDs(_ itemIDs: [String], maximumCount: Int) -> [String] {
        boundedUniqueDescriptors(
            itemIDs.map { ExternalCopyDragItemDescriptor(itemID: $0, contentKind: .unknown) },
            maximumCount: maximumCount
        ).map(\.itemID)
    }

    static func boundedUniqueDescriptors(
        _ descriptors: [ExternalCopyDragItemDescriptor],
        maximumCount: Int
    ) -> [ExternalCopyDragItemDescriptor] {
        guard maximumCount > 0 else { return [] }

        var seen: Set<String> = []
        var bounded: [ExternalCopyDragItemDescriptor] = []
        bounded.reserveCapacity(min(descriptors.count, maximumCount))

        for descriptor in descriptors where seen.insert(descriptor.itemID).inserted {
            bounded.append(descriptor)
            if bounded.count == maximumCount {
                break
            }
        }
        return bounded
    }
}

/// Runs successful-transfer follow-up work while retaining the payload's
/// app-level lease. The returned task is useful to deterministic tests; UIKit
/// callers intentionally let the task own itself until completion.
@MainActor
enum ExternalCopyDragFollowUp {
    @discardableResult
    static func start(
        payload: ExternalCopyDragPayload,
        evidence: [ExternalCopyTransferEvidence],
        completion: @escaping @MainActor ([ExternalCopyTransferEvidence]) async -> Void
    ) -> Task<Void, Never> {
        payload.cancelOutstandingLoads()
        guard payload.reserveFollowUp() else {
            return Task {}
        }
        let task = Task { @MainActor in
            defer { payload.finish() }
            guard !Task.isCancelled else { return }
            await completion(evidence)
        }
        payload.installFollowUp(task) {
            task.cancel()
        }
        return task
    }
}

/// Owns a `UIDragInteraction` and reports one completed external copy per drag
/// session. The owner must retain this object for at least as long as the
/// interaction is attached because `UIDragInteraction.delegate` is weak.
///
/// `makeItemProviders` may return one provider for a normal card drag or one
/// provider per selected card for a multi-item drag. A session-level callback
/// is intentional: UIKit's transfer-completed signal is also session-level.
@MainActor
final class ExternalCopyDragInteractionDelegate: NSObject, UIDragInteractionDelegate {
    typealias PayloadFactory = @MainActor () -> ExternalCopyDragPayload
    typealias Completion = @MainActor ([ExternalCopyTransferEvidence]) async -> Void
    typealias DestinationClassifier = @MainActor (any UIDragSession) -> Bool

    private struct SessionState {
        var gate = ExternalCopyTransferGate()
        let payload: ExternalCopyDragPayload
        let expiryToken = UUID()
        var expiryTask: Task<Void, Never>?
    }

    var makePayload: PayloadFactory
    var onExternalCopyTransferCompleted: Completion

    private let destinationClassifier: DestinationClassifier
    private var sessionStates: [ObjectIdentifier: SessionState] = [:]

    lazy var interaction: UIDragInteraction = {
        let interaction = UIDragInteraction(delegate: self)
        interaction.isEnabled = true
        return interaction
    }()

    init(
        makePayload: @escaping PayloadFactory,
        destinationClassifier: @escaping DestinationClassifier = ExternalDragDestinationClassifier
            .isOutsideVisibleApplicationWindows,
        onExternalCopyTransferCompleted: @escaping Completion
    ) {
        self.makePayload = makePayload
        self.destinationClassifier = destinationClassifier
        self.onExternalCopyTransferCompleted = onExternalCopyTransferCompleted
        super.init()
    }

    func dragInteraction(
        _: UIDragInteraction,
        itemsForBeginning session: any UIDragSession
    ) -> [UIDragItem] {
        let payload = makePayload()
        guard !payload.items.isEmpty else { return [] }

        let key = sessionKey(session)
        if let superseded = sessionStates.updateValue(
            SessionState(payload: payload),
            forKey: key
        ) {
            superseded.expiryTask?.cancel()
            superseded.payload.finish()
        }
        return payload.items.map { item in
            let dragItem = UIDragItem(itemProvider: item.itemProvider)
            dragItem.localObject = item.itemID as NSString
            return dragItem
        }
    }

    /// Cross-application drops are always copies on iOS. Disallowing moves
    /// avoids implying ownership-transfer semantics to a same-app target; an
    /// internal copy is still retained by the destination geometry gate.
    func dragInteraction(
        _: UIDragInteraction,
        sessionAllowsMoveOperation _: any UIDragSession
    ) -> Bool {
        false
    }

    func dragInteraction(
        _: UIDragInteraction,
        session: any UIDragSession,
        didEndWith operation: UIDropOperation
    ) {
        let key = sessionKey(session)
        guard var state = sessionStates[key] else { return }

        state.gate.recordEnd(
            operation: ExternalCopyTransferGate.Operation(operation),
            isOutsideApplicationWindows: destinationClassifier(session)
        )

        switch operation {
        case .copy:
            // UIKit promises a later sessionDidTransferItems callback after
            // the destination receives the requested data. Bound that wait:
            // third-party destinations do not always honor the callback.
            let expiryToken = state.expiryToken
            state.expiryTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(
                        nanoseconds: ExternalCopyDragSessionExpiryPolicy
                            .transferAcknowledgementTimeoutNanoseconds
                    )
                } catch {
                    return
                }
                self?.expireSessionState(key: key, scheduledToken: expiryToken)
            }
            sessionStates[key] = state
        case .cancel, .forbidden, .move:
            // These operations can never satisfy the gate, so discard their
            // state immediately and retain the source data.
            let removed = sessionStates.removeValue(forKey: key)
            removed?.expiryTask?.cancel()
            removed?.payload.finish()
        @unknown default:
            let removed = sessionStates.removeValue(forKey: key)
            removed?.expiryTask?.cancel()
            removed?.payload.finish()
        }
    }

    func dragInteraction(
        _: UIDragInteraction,
        sessionDidTransferItems session: any UIDragSession
    ) {
        let key = sessionKey(session)
        guard var state = sessionStates.removeValue(forKey: key) else { return }
        state.expiryTask?.cancel()
        guard state.gate.observeDataTransferCompleted() else {
            state.payload.finish()
            return
        }
        let successfullyTransferredEvidence = state.payload.completedTransferEvidence
        guard !successfullyTransferredEvidence.isEmpty else {
            state.payload.finish()
            return
        }

        // Provider work is finished, but keep the app-level transfer lease
        // alive until the successful-transfer follow-up has been admitted and
        // joined. Otherwise terminal suspension could seal the store between
        // this callback and an asynchronous conditional deletion.
        ExternalCopyDragFollowUp.start(
            payload: state.payload,
            evidence: successfullyTransferredEvidence,
            completion: onExternalCopyTransferCompleted
        )
    }

    private func sessionKey(_ session: any UIDragSession) -> ObjectIdentifier {
        ObjectIdentifier(session as AnyObject)
    }

    private func expireSessionState(key: ObjectIdentifier, scheduledToken: UUID) {
        guard ExternalCopyDragSessionExpiryPolicy.shouldExpire(
            currentToken: sessionStates[key]?.expiryToken,
            scheduledToken: scheduledToken
        ), let expired = sessionStates.removeValue(forKey: key)
        else { return }

        expired.payload.finish()
    }

    isolated deinit {
        for state in sessionStates.values {
            state.expiryTask?.cancel()
            state.payload.finish()
        }
    }
}

/// A transparent UIKit interaction surface for SwiftUI callers that want the
/// surface itself to own drag hit-testing. The coordinator retains the weak
/// UIKit delegate and updates its closures as SwiftUI state changes.
///
/// This view is intentionally not packaged as an overlay modifier: an overlay
/// interaction surface also owns taps and context-menu hit-testing. Callers
/// should compose it at the interaction layer that owns those gestures.
struct ExternalCopyDragInteractionView: UIViewRepresentable {
    let makePayload: ExternalCopyDragInteractionDelegate.PayloadFactory
    let onExternalCopyTransferCompleted: ExternalCopyDragInteractionDelegate.Completion
    let accessibilityName: String
    let accessibilityHint: String?

    func makeCoordinator() -> ExternalCopyDragInteractionDelegate {
        ExternalCopyDragInteractionDelegate(
            makePayload: makePayload,
            onExternalCopyTransferCompleted: onExternalCopyTransferCompleted
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isOpaque = false
        configureAccessibility(on: view)
        view.addInteraction(context.coordinator.interaction)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.makePayload = makePayload
        context.coordinator.onExternalCopyTransferCompleted = onExternalCopyTransferCompleted
        configureAccessibility(on: view)
    }

    private func configureAccessibility(on view: UIView) {
        view.isAccessibilityElement = true
        view.accessibilityLabel = accessibilityName
        view.accessibilityHint = accessibilityHint
        view.accessibilityDragSourceDescriptors = [
            UIAccessibilityLocationDescriptor(name: accessibilityName, view: view),
        ]
    }
}
