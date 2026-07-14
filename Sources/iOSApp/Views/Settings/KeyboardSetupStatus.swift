import ClipKittyShared
import UIKit

/// Current, truthful setup state derived at the UIKit boundary from two
/// independent facts: whether ClipKitty's input mode is enabled now, and
/// whether the extension has ever proved App Group access by opening.
enum KeyboardSetupStatus: Equatable {
    case unavailable
    case disabled
    case enabledAwaitingFirstUse
    case enabled(lastOpened: Date)

    private static let primaryLanguageInfoKey = "ClipKittyKeyboardPrimaryLanguage"

    @MainActor
    static func current() -> KeyboardSetupStatus {
        resolve(
            activePrimaryLanguages: UITextInputMode.activeInputModes.map(\.primaryLanguage),
            declaredPrimaryLanguage: Bundle.main.object(
                forInfoDictionaryKey: primaryLanguageInfoKey
            ) as? String,
            activationHistory: KeyboardFeedStore.activationHistory()
        )
    }

    static func resolve(
        activePrimaryLanguages: [String?],
        declaredPrimaryLanguage: String?,
        activationHistory: KeyboardFeedStore.ActivationHistory
    ) -> KeyboardSetupStatus {
        guard let declaredPrimaryLanguage else { return .unavailable }
        guard activePrimaryLanguages.contains(declaredPrimaryLanguage) else {
            return .disabled
        }

        switch activationHistory {
        case .neverOpened:
            return .enabledAwaitingFirstUse
        case let .opened(lastOpened):
            return .enabled(lastOpened: lastOpened)
        }
    }
}
