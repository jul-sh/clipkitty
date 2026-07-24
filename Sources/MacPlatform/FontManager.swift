import AppKit
import ClipKittyCore
import CoreText
import Foundation

public enum FontManager {
    public static func sansSerifName(for preference: AppFontPreference) -> String {
        switch preference {
        case .iosevkaCharon:
            let name = "IosevkaCharon-Regular"
            return fontAvailable(name) ? name : systemSansSerifName
        case .system:
            return systemSansSerifName
        }
    }

    public static func monoName(for preference: AppFontPreference) -> String {
        switch preference {
        case .iosevkaCharon:
            let name = "IosevkaCharonMono-Regular"
            return fontAvailable(name) ? name : systemMonospaceName
        case .system:
            return systemMonospaceName
        }
    }

    private static func fontAvailable(_ name: String) -> Bool {
        NSFont(name: name, size: 12) != nil
    }

    private static var systemSansSerifName: String {
        NSFont.systemFont(ofSize: 12).fontName
    }

    private static var systemMonospaceName: String {
        NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).fontName
    }

    public static func registerFonts() {
        guard let resourceURL = Bundle.main.resourceURL else {
            return
        }

        let fontsURL = resourceURL.appendingPathComponent("Fonts")

        guard let fontFiles = try? FileManager.default.contentsOfDirectory(
            at: fontsURL,
            includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension == "ttf" || $0.pathExtension == "otf" }),
            !fontFiles.isEmpty
        else {
            return
        }

        for fontURL in fontFiles {
            var errorRef: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &errorRef) {
                // Release the error to avoid memory leak
                _ = errorRef?.takeRetainedValue()
            }
        }
    }
}
