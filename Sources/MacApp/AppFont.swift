import ClipKittyMacPlatform
import SwiftUI

extension AppSettings {
    func appFont(size: CGFloat, weight: Font.Weight? = nil) -> Font {
        let font: Font = switch fontPreference {
        case .iosevkaCharon:
            .custom(FontManager.sansSerifName(for: .iosevkaCharon), size: size)
        case .system:
            .system(size: size)
        }
        return font.withWeight(weight)
    }

    func previewFont(size: CGFloat, weight: Font.Weight? = nil) -> Font {
        let font: Font = switch fontPreference {
        case .iosevkaCharon:
            .custom(FontManager.monoName(for: .iosevkaCharon), size: size)
        case .system:
            .system(size: size, design: .monospaced)
        }
        return font.withWeight(weight)
    }

    var previewFontName: String {
        FontManager.monoName(for: fontPreference)
    }
}

private extension Font {
    func withWeight(_ weight: Font.Weight?) -> Font {
        guard let weight else { return self }
        return self.weight(weight)
    }
}
