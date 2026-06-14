import CoreText
import SwiftUI
import UIKit

/// The UI typeface used across the app. Mirrors the macOS `AppFontPreference`
/// (see `Sources/MacPlatform/FontManager.swift`) so the two platforms persist
/// and reason about typeface choice identically.
public enum AppFontPreference: String, CaseIterable, Identifiable {
    case iosevkaCharon
    case system

    public var id: String {
        rawValue
    }
}

/// Character spacing for preview text. Mirrors the macOS `PreviewFontPreference`.
public enum PreviewFontPreference: String, CaseIterable, Identifiable {
    case coding
    case proportional

    public var id: String {
        rawValue
    }
}

enum FontManager {
    /// Default sans-serif PostScript name (Iosevka Charon when registered).
    static var sansSerif: String {
        sansSerifName(for: .iosevkaCharon)
    }

    /// Default monospace PostScript name (Iosevka Charon Mono when registered).
    static var mono: String {
        monoName(for: .iosevkaCharon)
    }

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

/// Sizing metrics that keep the system font visually balanced against Iosevka
/// Charon, mirroring `AppFontMetrics` on macOS.
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

/// Resolves SwiftUI fonts from the user's typeface preferences. This mirrors the
/// macOS `AppSettings.appFont(size:)` / `previewFont(size:)` helpers so both
/// apps render text with the same logic.
enum AppFont {
    /// The app UI font for the active typeface preference.
    static func ui(_ preference: AppFontPreference, size: CGFloat, weight: Font.Weight? = nil) -> Font {
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

extension Font {
    func withWeight(_ weight: Font.Weight?) -> Font {
        guard let weight else { return self }
        return self.weight(weight)
    }
}
