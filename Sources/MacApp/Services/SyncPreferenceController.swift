#if ENABLE_ICLOUD_SYNC

    import AppKit
    import Combine

    @MainActor
    final class SyncPreferenceController {
        private let applySyncEnabled: (Bool) -> Void
        private let registerForRemoteNotifications: () -> Void
        private var cancellable: AnyCancellable?

        init(
            applySyncEnabled: @escaping (Bool) -> Void,
            registerForRemoteNotifications: @escaping () -> Void
        ) {
            self.applySyncEnabled = applySyncEnabled
            self.registerForRemoteNotifications = registerForRemoteNotifications
        }

        func bind<Changes: Publisher>(
            initialValue: Bool,
            changes: Changes
        ) where Changes.Output == Bool, Changes.Failure == Never {
            cancellable = changes
                .prepend(initialValue)
                .removeDuplicates()
                .sink { [weak self] enabled in
                    // Hop off the current run-loop cycle so SwiftUI can render
                    // the toggle state change before CloudKit bootstrap blocks
                    // main on synchronous SecTrust/SecKey verification.
                    Task { @MainActor [weak self] in
                        self?.applyPreferenceChange(enabled)
                    }
                }
        }

        func unbind() {
            cancellable = nil
        }

        private func applyPreferenceChange(_ enabled: Bool) {
            applySyncEnabled(enabled)
            if enabled {
                registerForRemoteNotifications()
            }
        }
    }

#endif
