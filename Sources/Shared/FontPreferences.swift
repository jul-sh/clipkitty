import Foundation

public enum AppFontPreference: String, CaseIterable, Identifiable {
    case iosevkaCharon
    case system

    public var id: String {
        rawValue
    }
}

public enum PreviewFontPreference: String, CaseIterable, Identifiable {
    case coding
    case proportional

    public var id: String {
        rawValue
    }
}

public enum AppFontMetrics {
    private static let systemScale: CGFloat = 0.94

    public static func size(_ size: CGFloat, for preference: AppFontPreference) -> CGFloat {
        switch preference {
        case .iosevkaCharon:
            size
        case .system:
            size * systemScale
        }
    }
}
