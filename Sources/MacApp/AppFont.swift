import ClipKittyCore
import ClipKittyMacPlatform
import SwiftUI

extension AppSettings {
    func appFont(size: CGFloat, weight: Font.Weight? = nil) -> Font {
        AppFontSpecimen.uiFont(fontPreference, size: size, weight: weight)
    }

    func previewFont(size: CGFloat, weight: Font.Weight? = nil) -> Font {
        AppFontSpecimen.previewFont(
            typeface: fontPreference,
            style: previewFontPreference,
            size: size,
            weight: weight
        )
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

extension Font {
    func withWeight(_ weight: Font.Weight?) -> Font {
        guard let weight else { return self }
        return self.weight(weight)
    }
}

/// Builds fonts for a *specific* preference combination, independent of the
/// currently-selected settings. The Appearance specimen cards use these so each
/// card can render its own typeface even when it is not the active choice.
enum AppFontSpecimen {
    /// The app UI typeface for the given preference.
    static func uiFont(_ preference: AppFontPreference, size: CGFloat, weight: Font.Weight? = nil) -> Font {
        let size = AppFontMetrics.size(size, for: preference)
        let font: Font = switch preference {
        case .iosevkaCharon:
            .custom(FontManager.sansSerifName(for: .iosevkaCharon), size: size)
        case .system:
            .system(size: size)
        }
        return font.withWeight(weight)
    }

    /// The preview-pane text font for a given (typeface, preview-style) pair.
    static func previewFont(
        typeface: AppFontPreference,
        style: PreviewFontPreference,
        size: CGFloat,
        weight: Font.Weight? = nil
    ) -> Font {
        let size = AppFontMetrics.size(size, for: typeface)
        let font: Font = switch style {
        case .coding:
            switch typeface {
            case .iosevkaCharon:
                .custom(FontManager.monoName(for: .iosevkaCharon), size: size)
            case .system:
                .system(size: size, design: .monospaced)
            }
        case .proportional:
            switch typeface {
            case .iosevkaCharon:
                .custom(FontManager.sansSerifName(for: .iosevkaCharon), size: size)
            case .system:
                .system(size: size)
            }
        }
        return font.withWeight(weight)
    }
}
