import Foundation
import CoreText
import AppKit

enum FontManager {
    // Preferred custom fonts with system fallbacks
    static var sansSerif: String {
        fontAvailable("Iosevka Charon") ? "Iosevka Charon" : NSFont.systemFont(ofSize: 0).fontName
    }
    static var mono: String {
        fontAvailable("Iosevka Charon Mono") ? "Iosevka Charon Mono" : NSFont.monospacedSystemFont(ofSize: 0, weight: .regular).fontName
    }

    private static func fontAvailable(_ name: String) -> Bool {
        NSFont(name: name, size: 12) != nil
    }

    static func registerFonts() {
        guard let resourceURL = Bundle.module.resourceURL else {
            return
        }

        let fontsURL = resourceURL.appendingPathComponent("Fonts")

        guard let fontFiles = try? FileManager.default.contentsOfDirectory(
            at: fontsURL,
            includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension == "ttf" || $0.pathExtension == "otf" }),
              !fontFiles.isEmpty else {
            return
        }

        for fontURL in fontFiles {
            var errorRef: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &errorRef) {
                if let error = errorRef?.takeRetainedValue() {
                    logError("Failed to register font \(fontURL.lastPathComponent): \(error)")
                }
            }
        }
    }
}
