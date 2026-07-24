import Observation
import UIKit

/// Settings-aware haptics client. All haptic feedback flows through this client,
/// which checks `iOSSettingsStore.hapticsEnabled` before firing.
@MainActor
@Observable
final class HapticsClient {
    @ObservationIgnored
    private let settings: iOSSettingsStore

    init(settings: iOSSettingsStore) {
        self.settings = settings
    }

    enum Event {
        case copy
        case selection
        case success
        case destructive
    }

    func fire(_ event: Event) {
        guard settings.hapticsEnabled else { return }
        switch event {
        case .copy:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .destructive:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
}
