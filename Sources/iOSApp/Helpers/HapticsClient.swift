import Observation
import UIKit

/// App-wide haptics client. All haptic feedback flows through this client.
@MainActor
@Observable
final class HapticsClient {
    enum Event {
        case copy
        case selection
        case success
        case destructive
    }

    func fire(_ event: Event) {
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
