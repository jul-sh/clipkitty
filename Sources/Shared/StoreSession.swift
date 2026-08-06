import ClipKittyRust
import Foundation

/// A fully assembled store boundary. Callers cannot accidentally construct a
/// repository or ingestor around a different Rust store instance.
public struct StoreSession: Sendable {
    public let store: ClipKittyRust.ClipboardStore
    public let repository: ClipboardRepository

    public init(store: ClipKittyRust.ClipboardStore) {
        self.store = store
        repository = ClipboardRepository(store: store)
    }
}

/// Platform policy for the one conditional step in opening a store.
/// Path resolution and presentation of failures remain platform concerns.
public enum StoreIndexRepairStrategy: Sendable {
    /// Rebuild the derived index before returning the session.
    case rebuildImmediately
    /// Delegate repair to a platform-specific durable queue or scheduler.
    case custom(@Sendable (ClipKittyRust.ClipboardStore) throws -> Void)
}

/// The shared, path-independent store bootstrap boundary.
public enum StoreOpener {
    public static func inspect(path: String) throws -> StoreBootstrapPlan {
        try inspectStoreBootstrap(dbPath: path)
    }

    public static func open(
        path: String,
        repairStrategy: StoreIndexRepairStrategy,
        didConstructStore: @Sendable (ClipKittyRust.ClipboardStore) -> Void = { _ in }
    ) throws -> StoreSession {
        let plan = try inspect(path: path)
        return try open(
            path: path,
            plan: plan,
            repairStrategy: repairStrategy,
            didConstructStore: didConstructStore
        )
    }

    /// Accepts an already-inspected plan so UI owners can select a lifecycle
    /// state before performing a potentially expensive repair off-main-actor.
    public static func open(
        path: String,
        plan: StoreBootstrapPlan,
        repairStrategy: StoreIndexRepairStrategy,
        didConstructStore: @Sendable (ClipKittyRust.ClipboardStore) -> Void = { _ in }
    ) throws -> StoreSession {
        let store = try ClipKittyRust.ClipboardStore(dbPath: path)
        // Publish ownership before repair: expiration can now synchronously
        // seal and drain this exact store while repair observes terminal
        // admission instead of continuing with unowned file work.
        didConstructStore(store)
        switch plan {
        case .ready:
            break
        case .rebuildIndex:
            switch repairStrategy {
            case .rebuildImmediately:
                try store.rebuildIndex()
            case let .custom(repair):
                try repair(store)
            }
        }
        return StoreSession(store: store)
    }
}
