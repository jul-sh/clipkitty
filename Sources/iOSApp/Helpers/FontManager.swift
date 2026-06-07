import CoreText
import SwiftUI
import UIKit

enum FontManager {
    static var sansSerif: String {
        UIFont.systemFont(ofSize: 12).fontName
    }

    static var mono: String {
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
