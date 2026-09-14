import ClipKittyCore
import CoreText
import SwiftUI
import UIKit

enum FontManager {
    /// Sans-serif font name for the given typeface preference, falling back to
    /// the system font when the custom face is unavailable or `.system` is chosen.
    static func sansSerifName(for preference: AppFontPreference) -> String {
        switch preference {
        case .iosevkaCharon:
            let name = "IosevkaCharon-Regular"
            return fontAvailable(name) ? name : systemSansSerifName
        case .system:
            return systemSansSerifName
        }
    }

    /// Monospace font name for the given typeface preference, with the same
    /// availability fallback as `sansSerifName(for:)`.
    static func monoName(for preference: AppFontPreference) -> String {
        switch preference {
        case .iosevkaCharon:
            let name = "IosevkaCharonMono-Regular"
            return fontAvailable(name) ? name : systemMonospaceName
        case .system:
            return systemMonospaceName
        }
    }

    private static func fontAvailable(_ name: String) -> Bool {
        UIFont(name: name, size: 12) != nil
    }

    private static var systemSansSerifName: String {
        UIFont.systemFont(ofSize: 12).fontName
    }

    private static var systemMonospaceName: String {
        UIFont.monospacedSystemFont(ofSize: 12, weight: .regular).fontName
    }

    static func registerFonts() {
        guard let resourceURL = Bundle.main.resourceURL else { return }

        // Tuist flattens resources into the app bundle root
        guard let fontFiles = try? FileManager.default.contentsOfDirectory(
            at: resourceURL,
            includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension == "ttf" || $0.pathExtension == "otf" }),
            !fontFiles.isEmpty
        else { return }

        for fontURL in fontFiles {
            var errorRef: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &errorRef) {
                _ = errorRef?.takeRetainedValue()
            }
        }
    }
}

/// Resolves SwiftUI fonts from the user's typeface preferences. This mirrors the
/// macOS `AppSettings.appFont(size:)` / `previewFont(size:)` helpers so both
/// apps render text with the same logic.
/// Dynamic Type for point-sized fonts. Every card body, excerpt and preview
/// goes through `AppFont`, so this is the one place the user's text size
/// reaches the content rather than only the system-styled chrome around it.
/// `.custom(_:size:relativeTo:)` scales live; `.system(size:)` is fixed, so
/// it is run through `UIFontMetrics` at evaluation time instead.
enum DynamicTypeScaling {
    static func scaled(_ size: CGFloat) -> CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(for: size)
    }

    static func scaledFont(_ font: UIFont) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: font)
    }
}

enum AppFont {
    /// The app UI font for the active typeface preference.
    static func ui(_ preference: AppFontPreference, size: CGFloat, weight: Font.Weight? = nil) -> Font {
        let size = AppFontMetrics.size(size, for: preference)
        let font: Font = switch preference {
        case .iosevkaCharon:
            .custom(FontManager.sansSerifName(for: .iosevkaCharon), size: size, relativeTo: .body)
        case .system:
            .system(size: DynamicTypeScaling.scaled(size))
        }
        return font.withWeight(weight)
    }

    /// The preview-pane text font for a given (typeface, preview-style) pair.
    static func preview(
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
                .custom(FontManager.monoName(for: .iosevkaCharon), size: size, relativeTo: .body)
            case .system:
                .system(size: DynamicTypeScaling.scaled(size), design: .monospaced)
            }
        case .proportional:
            switch typeface {
            case .iosevkaCharon:
                .custom(FontManager.sansSerifName(for: .iosevkaCharon), size: size, relativeTo: .body)
            case .system:
                .system(size: DynamicTypeScaling.scaled(size))
            }
        }
        return font.withWeight(weight)
    }
}

extension Font {
    func withWeight(_ weight: Font.Weight?) -> Font {
        guard let weight else { return self }
        return self.weight(weight)
    }
}
