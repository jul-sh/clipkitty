#if ENABLE_ICLOUD_SYNC

    import ClipKittyRust

    enum iOSIndexBootstrapRepairPlan: Equatable {
        case notNeeded
        case queued(itemCount: UInt64)
    }

    enum iOSIndexMaintenance {
        static let batchLimit: UInt32 = 64

        static func queueBootstrapRepairIfNeeded(
            plan: StoreBootstrapPlan,
            store: ClipKittyRust.ClipboardStore
        ) throws -> iOSIndexBootstrapRepairPlan {
            switch plan {
            case .ready:
                return .notNeeded
            case .rebuildIndex:
                let itemCount = try store.enqueueFullIndexRebuild()
                return .queued(itemCount: itemCount)
            }
        }

        static func processQueuedBatch(
            store: ClipKittyRust.ClipboardStore
        ) throws -> IndexMaintenanceOutcome {
            try store.processIndexQueue(maxItems: batchLimit)
        }
    }

#endif
