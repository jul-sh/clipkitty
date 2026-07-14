import ClipKittyRust
import Foundation

/// Projects the authoritative clipboard database into the keyboard's bounded
/// App Group snapshot. It is shared by the containing app and out-of-process
/// mutation surfaces such as App Intents, so no writer has to duplicate the
/// keyboard feed's selection rules.
public struct KeyboardFeedSnapshotWriter: Sendable {
    public struct Candidate: Sendable {
        fileprivate let generation: UInt64
        fileprivate let items: [KeyboardFeedStore.Item]
    }

    public enum Failure: LocalizedError, Sendable {
        case database(ClipboardError)
        case file(String)

        public var errorDescription: String? {
            switch self {
            case let .database(error): error.localizedDescription
            case let .file(message): message
            }
        }
    }

    private let repository: ClipboardRepository
    private let baseDirectory: URL?

    public init(repository: ClipboardRepository, baseDirectory: URL? = nil) {
        self.repository = repository
        self.baseDirectory = baseDirectory
    }

    public func writeCurrentSnapshot() async -> Result<Void, Failure> {
        let candidate: Candidate
        switch await prepareCurrentSnapshot() {
        case let .success(prepared):
            candidate = prepared
        case let .failure(error):
            return .failure(error)
        }
        return write(candidate)
    }

    public func prepareCurrentSnapshot() async -> Result<Candidate, Failure> {
        let generation: UInt64
        do {
            generation = try KeyboardFeedStore.reserveGeneration(in: baseDirectory)
        } catch {
            return .failure(.file(error.localizedDescription))
        }
        let outcome = await repository.fetchRecentItems(
            scope: .textRepresentable(
                maxLength: UInt32(KeyboardFeedStore.maxInsertableTextLength)
            ),
            limit: UInt32(KeyboardFeedStore.maxItems)
        )

        let fetched: [ClipboardItem]
        switch outcome {
        case let .success(items):
            fetched = items
        case let .failure(error):
            return .failure(.database(error))
        }

        return .success(Candidate(
            generation: generation,
            items: fetched.compactMap(Self.feedItem(from:))
        ))
    }

    public func write(_ candidate: Candidate) -> Result<Void, Failure> {
        do {
            try KeyboardFeedStore.write(
                items: candidate.items,
                generation: candidate.generation,
                in: baseDirectory
            )
            return .success(())
        } catch {
            return .failure(.file(error.localizedDescription))
        }
    }

    private static func feedItem(from item: ClipboardItem) -> KeyboardFeedStore.Item? {
        let metadata = item.itemMetadata
        let kind: KeyboardFeedStore.Item.Kind
        let text: String
        var colorRGBA: UInt32?

        switch item.content {
        case let .text(value):
            kind = .text
            text = value
        case let .link(url, _):
            kind = .link
            text = url
        case let .color(value):
            kind = .color
            text = value
            if case let .colorSwatch(rgba) = metadata.icon {
                colorRGBA = rgba
            }
        case .image, .file:
            return nil
        }

        // The database scope enforces these boundaries. Keep this guard at
        // the serialization boundary as defense against corrupt legacy rows.
        guard !text.isEmpty,
              text.count <= KeyboardFeedStore.maxInsertableTextLength
        else {
            return nil
        }

        return KeyboardFeedStore.Item(
            id: metadata.itemId,
            kind: kind,
            text: text,
            sourceApp: metadata.sourceApp,
            timestampUnix: metadata.timestampUnix,
            colorRGBA: colorRGBA
        )
    }
}
