import ClipKittyMacPlatform
import SwiftUI

enum AppFontMetrics {
    private static let systemScale: CGFloat = 0.94

    static func size(_ size: CGFloat, for preference: AppFontPreference) -> CGFloat {
        switch preference {
        case .iosevkaCharon:
            return size
        case .system:
            return size * systemScale
        }
    }
}

extension AppSettings {
    func appFont(size: CGFloat, weight: Font.Weight? = nil) -> Font {
        let size = AppFontMetrics.size(size, for: fontPreference)
        let font: Font = switch fontPreference {
        case .iosevkaCharon:
            .custom(FontManager.sansSerifName(for: .iosevkaCharon), size: size)
        case .system:
            .system(size: size)
        }
        return font.withWeight(weight)
    }

    func previewFont(size: CGFloat, weight: Font.Weight? = nil) -> Font {
        let size = previewFontSize(size)
        let font: Font = switch previewFontPreference {
        case .coding:
            switch fontPreference {
            case .iosevkaCharon:
                .custom(FontManager.monoName(for: .iosevkaCharon), size: size)
            case .system:
                .system(size: size, design: .monospaced)
            }
        case .proportional:
            switch fontPreference {
            case .iosevkaCharon:
                .custom(FontManager.sansSerifName(for: .iosevkaCharon), size: size)
            case .system:
                .system(size: size)
            }
        }
        return font.withWeight(weight)
    }

    func previewFontSize(_ size: CGFloat) -> CGFloat {
        AppFontMetrics.size(size, for: fontPreference)
    }

    var previewFontName: String {
        switch previewFontPreference {
        case .coding:
            return FontManager.monoName(for: fontPreference)
        case .proportional:
            return FontManager.sansSerifName(for: fontPreference)
        }
    }
}

private extension Font {
    func withWeight(_ weight: Font.Weight?) -> Font {
        guard let weight else { return self }
        return self.weight(weight)
    }
}
