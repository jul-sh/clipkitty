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
    /// The system faces render visibly larger than Iosevka Charon at the same
    /// point size, so they are scaled down a touch to keep the two typeface
    /// choices at the same apparent size. 0.94 read as slightly small in
    /// practice; 0.97 keeps the parity without the shrink.
    private static let systemScale: CGFloat = 0.97

    public static func size(_ size: CGFloat, for preference: AppFontPreference) -> CGFloat {
        switch preference {
        case .iosevkaCharon:
            size
        case .system:
            size * systemScale
        }
    }
}
