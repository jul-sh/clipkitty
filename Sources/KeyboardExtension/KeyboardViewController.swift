import ClipKittyShared
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Principal class of the ClipKitty keyboard extension. The keyboard has no
/// keys — it renders the recent-clips feed (from the App Group snapshot the
/// main app maintains; see `KeyboardFeedStore`) and inserts a clip's text at
/// the cursor when a card is tapped. Cards are also drag sources, so a clip
/// can be dropped anywhere in the host app.
///
/// Opening the keyboard also captures new clipboard content: anything copied
/// since ClipKitty last looked is enqueued for the main app (the same
/// `PendingShareQueue` the share extension uses) and shown at the top of the
/// strip immediately.
final class KeyboardViewController: UIInputViewController {
    /// Taller than a bare QWERTY board (~216pt) so cards get room to show a
    /// useful excerpt, but shy of GIF-keyboard heights that feel like a modal.
    private static let keyboardHeight: CGFloat = 270

    private enum PresentationState {
        case offscreen
        case presented
    }

    private let model = KeyboardFeedModel()
    private var presentationState: PresentationState = .offscreen
    private var feedObservationTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()

        let host = UIHostingController(
            rootView: KeyboardRootView(
                model: model,
                insertText: { [weak self] text in
                    self?.textDocumentProxy.insertText(text)
                },
                openSearchInApp: { [weak self] in
                    self?.openApp(link: .search)
                },
                inputModeSwitchTarget: self
            )
        )
        // Keep the system's keyboard backdrop visible behind the feed.
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        // High-but-not-required so the system can win during rotation and
        // floating-keyboard transitions instead of throwing constraint errors.
        let height = view.heightAnchor.constraint(equalToConstant: Self.keyboardHeight)
        height.priority = UILayoutPriority(999)
        height.isActive = true

        feedObservationTask = Task { @MainActor [weak self] in
            for await _ in KeyboardFeedStore.changes(for: .feed) {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                switch self.presentationState {
                case .offscreen:
                    break
                case .presented:
                    self.reloadModel()
                }
            }
        }
    }

    deinit {
        feedObservationTask?.cancel()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        presentationState = .presented
        // `needsInputModeSwitchKey` isn't reliable until the view is about to
        // appear, so the globe key is decided here, not in viewDidLoad.
        model.needsGlobeKey = needsInputModeSwitchKey
        reloadModel()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        presentationState = .offscreen
    }

    private func reloadModel() {
        model.reload(from: .read(hasFullAccess: hasFullAccess))
    }

    // MARK: - Opening the main app

    /// Keyboard extensions have no supported way to open their containing
    /// app: `extensionContext.open` reports failure here (it's honored only
    /// for Today widgets), so we fall back to performing UIApplication's
    /// `openURL:options:completionHandler:` up the responder chain — the
    /// long-standing pattern third-party keyboards use. The system then asks
    /// the user to confirm ("Open in ClipKitty?") before foregrounding the
    /// app. The deprecated `openURL:` no longer works from keyboards on
    /// iOS 26; only the options-variant reaches LaunchServices.
    private func openApp(link: AppDeepLink) {
        let url = link.url
        if let extensionContext {
            extensionContext.open(url) { [weak self] success in
                guard !success else { return }
                DispatchQueue.main.async {
                    self?.openViaResponderChain(url)
                }
            }
        } else {
            openViaResponderChain(url)
        }
    }

    private func openViaResponderChain(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                open(url, via: application)
                return
            }
            responder = current.next
        }
    }

    private func open(_ url: URL, via application: UIApplication) {
        let selector = sel_registerName("openURL:options:completionHandler:")
        guard application.responds(to: selector) else { return }
        typealias OpenFunction = @convention(c) (
            NSObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?
        ) -> Void
        let open = unsafeBitCast(application.method(for: selector), to: OpenFunction.self)
        open(application, selector, url as NSURL, [:], nil)
    }
}

// MARK: - Model

/// Keyboard-side view state, derived on every appearance from the snapshot,
/// the pending queue, and the pasteboard.
@MainActor
@Observable
final class KeyboardFeedModel {
    /// Parsed boundary state for App Group access and snapshot availability.
    /// Once constructed, callers never need to combine a permission boolean
    /// with an optional snapshot.
    enum FeedSource {
        case restricted
        case accessibleWithoutSnapshot
        case snapshot(KeyboardFeedStore.Snapshot)

        static func read(hasFullAccess: Bool) -> FeedSource {
            if let snapshot = KeyboardFeedStore.loadSnapshot() {
                return .snapshot(snapshot)
            }
            return hasFullAccess ? .accessibleWithoutSnapshot : .restricted
        }
    }

    /// One card in the strip.
    enum Card: Identifiable {
        /// A regular insertable clip — from the snapshot, or text/link content
        /// an extension captured that the app hasn't ingested yet.
        case clip(KeyboardFeedStore.Item)
        /// An image captured from the pasteboard, not yet ingested. It can't
        /// be inserted as text, but it can be dragged into the host app.
        case capturedImage(CapturedImageCard)

        var id: String {
            switch self {
            case let .clip(item): return item.id
            case let .capturedImage(card): return card.id
            }
        }

        var timestampUnix: Int64 {
            switch self {
            case let .clip(item): item.timestampUnix
            case let .capturedImage(card): card.timestampUnix
            }
        }
    }

    struct CapturedImageCard: Identifiable {
        let id: String
        let thumbnail: UIImage?
        let fileURL: URL
        let utType: UTType
        let timestampUnix: Int64
    }

    enum State {
        case loading
        /// Full access is off, so the App Group container (and with it the
        /// snapshot) is unreachable.
        case needsFullAccess
        /// Setup is complete but there is nothing to show yet.
        case empty
        case ready([Card])
    }

    private(set) var state: State = .loading
    var needsGlobeKey = false

    /// Keyboard extensions live under a tight memory budget; captured images
    /// beyond this stay on the pasteboard only.
    private static let maxCapturedImageBytes = 20 * 1024 * 1024

    func reload(from source: FeedSource) {
        let snapshotItems: [KeyboardFeedStore.Item]
        switch source {
        case .restricted:
            state = .needsFullAccess
            return
        case .accessibleWithoutSnapshot:
            snapshotItems = []
        case let .snapshot(snapshot):
            snapshotItems = snapshot.items
        }

        // Reaching this point proves the whole setup chain (keyboard enabled,
        // clip history readable) works — record it so the app's activation
        // flow can show success.
        KeyboardFeedStore.recordKeyboardOpened()

        captureFromPasteboard()

        let pendingCards = PendingShareQueue.peekAll()
            .compactMap(Self.card(fromPending:))
        let snapshotCards = snapshotItems.map(Card.clip)

        let cards = Array((pendingCards + snapshotCards)
            .sorted { $0.timestampUnix > $1.timestampUnix }
            .prefix(KeyboardFeedStore.maxItems))
        state = cards.isEmpty ? .empty : .ready(cards)
    }

    // MARK: - Pasteboard capture

    /// Saves new clipboard content into history via the pending queue. Gated
    /// on `changeCount` (which never triggers the system paste prompt) against
    /// the shared cross-process marker, so content the app already ingested —
    /// or that ClipKitty itself copied — is never captured twice, and a
    /// declined paste prompt is not re-asked for the same generation.
    private func captureFromPasteboard() {
        let pasteboard = UIPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != PasteboardIngestState.lastChangeCount() else { return }

        // Record before reading, like the app's auto-add: a denial or
        // unreadable content is respected, not retried.
        PasteboardIngestState.recordChangeCount(changeCount)

        // Same priority order as the app's readCurrentClipboard.
        if pasteboard.hasImages {
            captureImage(from: pasteboard)
        } else if pasteboard.hasURLs, let url = pasteboard.url {
            try? PendingShareQueue.enqueueURL(url.absoluteString, origin: .keyboard)
        } else if pasteboard.hasStrings, let string = pasteboard.string, !string.isEmpty {
            try? PendingShareQueue.enqueueText(string, origin: .keyboard)
        }
    }

    private func captureImage(from pasteboard: UIPasteboard) {
        // Prefer the raw encoded bytes — no full-bitmap decode in a
        // memory-constrained process; re-encode only as a last resort.
        let data = pasteboard.data(forPasteboardType: UTType.png.identifier)
            ?? pasteboard.data(forPasteboardType: UTType.jpeg.identifier)
            ?? pasteboard.image?.pngData()
        guard let data, !data.isEmpty, data.count <= Self.maxCapturedImageBytes else { return }

        // preparingThumbnail downsamples via ImageIO without decoding the
        // full bitmap first.
        let thumbnail = UIImage(data: data)?
            .preparingThumbnail(of: CGSize(width: 400, height: 400))?
            .jpegData(compressionQuality: 0.7)
        try? PendingShareQueue.enqueueImage(imageData: data, thumbnail: thumbnail, origin: .keyboard)
    }

    // MARK: - Pending → card

    private static func card(fromPending pending: PendingShareQueue.PeekedItem) -> Card? {
        let timestamp = Int64(pending.enqueuedAt.timeIntervalSince1970)
        let sourceApp = switch pending.origin {
        case .keyboard: "Pasteboard"
        case .shareSheet: "Share Sheet"
        }
        switch pending.item {
        case let .text(text):
            return .clip(KeyboardFeedStore.Item(
                id: "pending-\(pending.id)",
                kind: .text,
                text: text,
                sourceApp: sourceApp,
                timestampUnix: timestamp
            ))
        case let .url(url):
            return .clip(KeyboardFeedStore.Item(
                id: "pending-\(pending.id)",
                kind: .link,
                text: url,
                sourceApp: sourceApp,
                timestampUnix: timestamp
            ))
        case .image:
            guard let fileURL = pending.imageFileURL else { return nil }
            return .capturedImage(CapturedImageCard(
                id: "pending-\(pending.id)",
                thumbnail: pending.thumbnailData.flatMap(UIImage.init(data:)),
                fileURL: fileURL,
                utType: Self.imageType(of: fileURL),
                timestampUnix: timestamp
            ))
        }
    }

    /// Sniffs the stored image's magic bytes so the drag provider offers the
    /// type the bytes actually are.
    private static func imageType(of fileURL: URL) -> UTType {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return .png }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 3) else { return .png }
        return prefix.starts(with: [0xFF, 0xD8]) ? .jpeg : .png
    }
}
