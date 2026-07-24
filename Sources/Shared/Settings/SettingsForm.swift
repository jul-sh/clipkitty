import SwiftUI

/// The common top-level Settings structure used by both Apple apps.
///
/// Platform targets provide only their platform-specific sections and effects;
/// shared sections stay in one place and therefore cannot drift in order or
/// presentation between iOS and macOS.
public struct SettingsForm<
    GeneralSections: View,
    PrivacySections: View,
    SyncSections: View,
    PlatformSections: View,
    ShortcutsSections: View,
    AdvancedSections: View
>: View {
    @Binding private var fontPreference: AppFontPreference
    @Binding private var previewFontPreference: PreviewFontPreference

    private let uiFont: (AppFontPreference, CGFloat, Font.Weight?) -> Font
    private let previewFont:
        (AppFontPreference, PreviewFontPreference, CGFloat, Font.Weight?) -> Font
    private let onAppearanceSelection: () -> Void
    private let generalSections: () -> GeneralSections
    private let privacySections: () -> PrivacySections
    private let syncSections: () -> SyncSections
    private let platformSections: () -> PlatformSections
    private let shortcutsSections: () -> ShortcutsSections
    private let advancedSections: () -> AdvancedSections

    public init(
        fontPreference: Binding<AppFontPreference>,
        previewFontPreference: Binding<PreviewFontPreference>,
        uiFont: @escaping (AppFontPreference, CGFloat, Font.Weight?) -> Font,
        previewFont: @escaping (
            AppFontPreference,
            PreviewFontPreference,
            CGFloat,
            Font.Weight?
        ) -> Font,
        onAppearanceSelection: @escaping () -> Void = {},
        @ViewBuilder generalSections: @escaping () -> GeneralSections,
        @ViewBuilder privacySections: @escaping () -> PrivacySections,
        @ViewBuilder syncSections: @escaping () -> SyncSections,
        @ViewBuilder platformSections: @escaping () -> PlatformSections,
        @ViewBuilder shortcutsSections: @escaping () -> ShortcutsSections,
        @ViewBuilder advancedSections: @escaping () -> AdvancedSections
    ) {
        _fontPreference = fontPreference
        _previewFontPreference = previewFontPreference
        self.uiFont = uiFont
        self.previewFont = previewFont
        self.onAppearanceSelection = onAppearanceSelection
        self.generalSections = generalSections
        self.privacySections = privacySections
        self.syncSections = syncSections
        self.platformSections = platformSections
        self.shortcutsSections = shortcutsSections
        self.advancedSections = advancedSections
    }

    public var body: some View {
        Form {
            generalSections()
            privacySections()

            SettingsAppearanceSection(
                fontPreference: $fontPreference,
                previewFontPreference: $previewFontPreference,
                uiFont: uiFont,
                previewFont: previewFont,
                onSelection: onAppearanceSelection
            )

            syncSections()
            platformSections()
            shortcutsSections()
            advancedSections()
        }
        .formStyle(.grouped)
    }
}
