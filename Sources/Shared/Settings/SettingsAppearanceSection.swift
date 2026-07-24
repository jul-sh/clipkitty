import SwiftUI

/// The shared Appearance section. Font lookup stays in each platform adapter,
/// while option structure, copy, selection behavior, and specimens stay here.
public struct SettingsAppearanceSection: View {
    @Binding private var fontPreference: AppFontPreference
    @Binding private var previewFontPreference: PreviewFontPreference

    private let uiFont: (AppFontPreference, CGFloat, Font.Weight?) -> Font
    private let previewFont:
        (AppFontPreference, PreviewFontPreference, CGFloat, Font.Weight?) -> Font
    private let onSelection: () -> Void

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
        onSelection: @escaping () -> Void = {}
    ) {
        _fontPreference = fontPreference
        _previewFontPreference = previewFontPreference
        self.uiFont = uiFont
        self.previewFont = previewFont
        self.onSelection = onSelection
    }

    public var body: some View {
        Section(String(localized: "Appearance")) {
            SettingsSubgroup(title: String(localized: "App Typeface")) {
                ForEach(AppFontPreference.allCases) { preference in
                    SettingsChoiceRow(
                        title: typefaceTitle(preference),
                        description: typefaceDescription(preference),
                        isSelected: fontPreference == preference,
                        onSelect: {
                            fontPreference = preference
                            onSelection()
                        }
                    ) {
                        Text(verbatim: "Aa Gg")
                            .font(uiFont(preference, 17, .medium))
                            .lineLimit(1)
                    }
                }
            }

            Divider()

            SettingsSubgroup(title: String(localized: "Preview Spacing")) {
                ForEach(PreviewFontPreference.allCases) { style in
                    SettingsChoiceRow(
                        title: spacingTitle(style),
                        description: spacingDescription(style),
                        isSelected: previewFontPreference == style,
                        onSelect: {
                            previewFontPreference = style
                            onSelection()
                        }
                    ) {
                        Text(verbatim: "il 012")
                            .font(previewFont(fontPreference, style, 15, .medium))
                            .lineLimit(1)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: fontPreference)
        .animation(.easeInOut(duration: 0.18), value: previewFontPreference)
    }

    private func typefaceTitle(_ preference: AppFontPreference) -> String {
        switch preference {
        case .iosevkaCharon:
            return String(localized: "Iosevka Charon")
        case .system:
            return String(localized: "System")
        }
    }

    private func typefaceDescription(_ preference: AppFontPreference) -> String {
        switch preference {
        case .iosevkaCharon:
            return String(localized: "ClipKitty's dense, distinctive typeface.")
        case .system:
            return String(localized: "The native system font.")
        }
    }

    private func spacingTitle(_ style: PreviewFontPreference) -> String {
        switch style {
        case .coding:
            return String(localized: "Monospace")
        case .proportional:
            return String(localized: "Proportional")
        }
    }

    private func spacingDescription(_ style: PreviewFontPreference) -> String {
        switch style {
        case .coding:
            return String(localized: "Even-width characters; columns line up. Great for code.")
        case .proportional:
            return String(localized: "Natural spacing; easier to read. Good for prose.")
        }
    }
}

/// A shared selectable Settings row used by Appearance and platform pickers.
public struct SettingsChoiceRow<Accessory: View>: View {
    private let title: String
    private let description: String
    private let isSelected: Bool
    private let onSelect: () -> Void
    private let accessory: () -> Accessory

    public init(
        title: String,
        description: String,
        isSelected: Bool,
        onSelect: @escaping () -> Void,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.title = title
        self.description = description
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.accessory = accessory
    }

    public var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                accessory()
                    .foregroundStyle(.secondary)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

public extension SettingsChoiceRow where Accessory == EmptyView {
    init(
        title: String,
        description: String,
        isSelected: Bool,
        onSelect: @escaping () -> Void
    ) {
        self.init(
            title: title,
            description: description,
            isSelected: isSelected,
            onSelect: onSelect,
            accessory: { EmptyView() }
        )
    }
}

private struct SettingsSubgroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            content()
        }
        .padding(.vertical, 2)
    }
}
