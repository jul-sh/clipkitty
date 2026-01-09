import Foundation
import CoreText

enum FontManager {
    static let sansSerif = "Iosevka Charon"
    static let mono = "Iosevka Charon Mono"

    static func registerFonts() {
        guard let resourceURL = Bundle.module.resourceURL else {
            print("Could not find bundle resource URL")
            return
        }

        let fontsURL = resourceURL.appendingPathComponent("Fonts")

        do {
            let fontFiles = try FileManager.default.contentsOfDirectory(
                at: fontsURL,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "ttf" || $0.pathExtension == "otf" }

            for fontURL in fontFiles {
                var errorRef: Unmanaged<CFError>?
                if !CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &errorRef) {
                    if let error = errorRef?.takeRetainedValue() {
                        print("Failed to register font \(fontURL.lastPathComponent): \(error)")
                    }
                }
            }
        } catch {
            print("Failed to enumerate fonts directory: \(error)")
        }
    }
}
