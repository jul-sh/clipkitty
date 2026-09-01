import ClipKittyRust
import SwiftUI
import UIKit

struct ExternalCopyDragItem {
    let itemID: String
    let itemProvider: NSItemProvider
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
    private let transferSession: DragItemProvider.TransferSession
    private var externalTransferLease: AppExternalTransferLease?
    private var cleanupTask: Task<Void, Never>?

    init(
        transferSession: DragItemProvider.TransferSession,
        externalTransferLease: AppExternalTransferLease?
    ) {
        self.transferSession = transferSession
        self.externalTransferLease = externalTransferLease
        externalTransferLease?.installExpirationHandler({ [weak self] in
            self?.finish()
        }, requiresCleanup: true)
    }

    func cancelOutstandingLoads() {
        transferSession.cancel()
    }

    func finish() {
        guard cleanupTask == nil else { return }

        // Move all terminal ownership into one task. It retains the lease (and
        // therefore AppState's latch) until cancellation has reached every
        // memoized fetch. The task does not capture `self`, avoiding a
        // payload/task retain cycle during UIKit teardown.
        let transferSession = transferSession
        let lease = externalTransferLease
        externalTransferLease = nil
        cleanupTask = Task { @MainActor in
            await transferSession.cancelAndWait()
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
        fetchItem: @escaping @Sendable (String) async -> ClipboardItem?
    ) {
        self.init(
            descriptors: itemIDs.map {
                ExternalCopyDragItemDescriptor(itemID: $0, contentKind: .unknown)
            },
            policy: policy,
            externalTransferLease: externalTransferLease,
            fetchItem: fetchItem
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
        fetchItem: @escaping @Sendable (String) async -> ClipboardItem?
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
            ExternalCopyDragItem(
                itemID: descriptor.itemID,
                itemProvider: DragItemProvider.make(
                    itemId: descriptor.itemID,
                    contentKind: descriptor.contentKind,
                    transferSession: transferSession,
                    fetch: { itemID in
                        guard let item = await fetchItem(itemID),
                              item.itemMetadata.itemId == itemID
                        else { return nil }
                        return item
                    }
                )
            )
        }
    }

    var itemIDs: [String] {
        items.map(\.itemID)
    }

    @MainActor
    func cancelOutstandingLoads() {
        lifetime?.cancelOutstandingLoads()
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

/// Owns a `UIDragInteraction`. The owner must retain this object for at least
/// as long as the interaction is attached because `UIDragInteraction.delegate`
/// is weak.
///
/// `makeItemProviders` may return one provider for a normal card drag or one
/// provider per selected card for a multi-item drag.
@MainActor
final class ExternalCopyDragInteractionDelegate: NSObject, UIDragInteractionDelegate {
    typealias PayloadFactory = @MainActor () -> ExternalCopyDragPayload

    var makePayload: PayloadFactory

    private var payloadsBySession: [ObjectIdentifier: ExternalCopyDragPayload] = [:]

    lazy var interaction: UIDragInteraction = {
        let interaction = UIDragInteraction(delegate: self)
        interaction.isEnabled = true
        return interaction
    }()

    init(makePayload: @escaping PayloadFactory) {
        self.makePayload = makePayload
        super.init()
    }

    func dragInteraction(
        _: UIDragInteraction,
        itemsForBeginning session: any UIDragSession
    ) -> [UIDragItem] {
        let payload = makePayload()
        guard !payload.items.isEmpty else { return [] }

        let key = sessionKey(session)
        if let superseded = payloadsBySession.updateValue(payload, forKey: key) {
            superseded.finish()
        }
        return payload.items.map { item in
            let dragItem = UIDragItem(itemProvider: item.itemProvider)
            dragItem.localObject = item.itemID as NSString
            return dragItem
        }
    }

    /// Cross-application drops are always copies on iOS. Disallowing moves
    /// avoids implying ownership-transfer semantics to a same-app target.
    func dragInteraction(
        _: UIDragInteraction,
        sessionAllowsMoveOperation _: any UIDragSession
    ) -> Bool {
        false
    }

    func dragInteraction(
        _: UIDragInteraction,
        session: any UIDragSession,
        didEndWith _: UIDropOperation
    ) {
        let key = sessionKey(session)
        payloadsBySession.removeValue(forKey: key)?.finish()
    }

    private func sessionKey(_ session: any UIDragSession) -> ObjectIdentifier {
        ObjectIdentifier(session as AnyObject)
    }

    isolated deinit {
        for payload in payloadsBySession.values {
            payload.finish()
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
    let accessibilityName: String
    let accessibilityHint: String?

    func makeCoordinator() -> ExternalCopyDragInteractionDelegate {
        ExternalCopyDragInteractionDelegate(makePayload: makePayload)
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
