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

    private let model = KeyboardFeedModel()

    override func viewDidLoad() {
        super.viewDidLoad()

        let host = UIHostingController(
            rootView: KeyboardRootView(
                model: model,
                insertText: { [weak self] text in
                    self?.textDocumentProxy.insertText(text)
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
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // `needsInputModeSwitchKey` isn't reliable until the view is about to
        // appear, so the globe key is decided here, not in viewDidLoad.
        model.needsGlobeKey = needsInputModeSwitchKey
        model.reload(hasFullAccess: hasFullAccess)
    }
}

// MARK: - Model

/// Keyboard-side view state, derived on every appearance from the snapshot,
/// the pending queue, and the pasteboard.
@MainActor
@Observable
final class KeyboardFeedModel {
    /// One card in the strip.
    enum Card: Identifiable {
        /// A regular insertable clip — from the snapshot, or text/link content
        /// this keyboard captured that the app hasn't ingested yet.
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
    }

    struct CapturedImageCard: Identifiable {
        let id: String
        let thumbnail: UIImage?
        let fileURL: URL
        let utType: UTType
        let timestampUnix: Int64
    }

    enum State {
        /// Full access is off, so the App Group container (and with it the
        /// snapshot) is unreachable.
        case needsFullAccess
        /// Setup is complete but there is nothing to show yet.
        case empty
        case ready([Card])
    }

    private(set) var state: State = .empty
    var needsGlobeKey = false

    /// Keyboard extensions live under a tight memory budget; captured images
    /// beyond this stay on the pasteboard only.
    private static let maxCapturedImageBytes = 20 * 1024 * 1024

    func reload(hasFullAccess: Bool) {
        guard hasFullAccess else {
            state = .needsFullAccess
            return
        }
        // Reaching this point proves the whole setup chain (keyboard enabled,
        // full access granted) works — record it so the app's activation flow
        // can show success.
        KeyboardFeedStore.recordKeyboardOpened()

        captureFromPasteboard()

        let pendingCards = PendingShareQueue.peekAll()
            .filter { $0.origin == .keyboard }
            .compactMap(Self.card(fromPending:))
        let snapshotCards = (KeyboardFeedStore.loadSnapshot()?.items ?? []).map(Card.clip)

        let cards = pendingCards + snapshotCards
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
        switch pending.item {
        case let .text(text):
            return .clip(KeyboardFeedStore.Item(
                id: "pending-\(pending.id)",
                kind: .text,
                text: text,
                sourceApp: "Pasteboard",
                timestampUnix: timestamp
            ))
        case let .url(url):
            return .clip(KeyboardFeedStore.Item(
                id: "pending-\(pending.id)",
                kind: .link,
                text: url,
                sourceApp: "Pasteboard",
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
