import AppKit
import ClipKittyMacPlatform
import Combine
@preconcurrency import CoreGraphics
import Foundation

enum PasteMode {
    case noPermission
    case copyOnly
    case autoPaste

    var buttonLabel: String {
        switch self {
        case .noPermission, .copyOnly:
            return String(localized: "Copy")
        case .autoPaste:
            return String(localized: "Paste")
        }
    }

    var editConfirmLabel: String {
        switch self {
        case .noPermission, .copyOnly:
            return String(localized: "Save & Copy")
        case .autoPaste:
            return String(localized: "Save & Paste")
        }
    }
}

#if ENABLE_SPARKLE_UPDATES
    enum UpdateCheckState: Equatable {
        case idle
        case checking
        case downloading
        case installing
        case available
        case checkFailed(errorMessage: String)
    }
#endif

/// Process-local settings state derived from system services or active work.
/// None of these values are written by AppSettings' preferences serializer.
@MainActor
final class AppRuntimeState: ObservableObject {
    static let shared = AppRuntimeState()

    let accessibilityPermissionMonitor: AccessibilityPermissionMonitor
    @Published private(set) var textScale: CGFloat

    #if ENABLE_SPARKLE_UPDATES
        @Published var updateCheckState: UpdateCheckState = .idle
    #endif

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private var textScaleObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        accessibilityPermissionMonitor: AccessibilityPermissionMonitor? = nil
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.accessibilityPermissionMonitor = accessibilityPermissionMonitor ?? AccessibilityPermissionMonitor()
        textScale = Self.systemTextScale(defaults: defaults)
        textScaleObserver = notificationCenter.addObserver(
            forName: NSNotification.Name("NSPreferredContentSizeCategoryDidChangeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.textScale = Self.systemTextScale(defaults: self.defaults)
            }
        }
    }

    #if ENABLE_SYNTHETIC_PASTE
        var pasteMode: PasteMode {
            #if ENABLE_TEST_FIXTURES
                if CommandLine.arguments.contains("--force-paste-mode") {
                    return .autoPaste
                }
            #endif
            guard AppSettings.shared.autoPasteEnabled else { return .copyOnly }
            guard accessibilityPermissionMonitor.isGranted else { return .noPermission }
            return .autoPaste
        }
    #else
        var pasteMode: PasteMode {
            .copyOnly
        }
    #endif

    func scaled(_ size: CGFloat) -> CGFloat {
        size * textScale
    }

    private static func systemTextScale(defaults: UserDefaults) -> CGFloat {
        let category = defaults.string(forKey: "UIPreferredContentSizeCategoryName")
            ?? "UICTContentSizeCategoryL"
        let scale: CGFloat = switch category {
        case "UICTContentSizeCategoryXS", "UICTContentSizeCategoryS",
             "UICTContentSizeCategoryM", "UICTContentSizeCategoryL":
            1.0
        case "UICTContentSizeCategoryXL":
            1.12
        case "UICTContentSizeCategoryXXL":
            1.24
        case "UICTContentSizeCategoryXXXL":
            1.35
        default:
            1.5
        }
        return min(scale, 1.5)
    }

    deinit {
        if let textScaleObserver {
            notificationCenter.removeObserver(textScaleObserver)
        }
    }
}
