import SwiftUI

/// "App Typeface" + "Preview Spacing" settings, mirroring the macOS
/// `AppearanceSettingsView`. Where the Mac shows radio rows beside one shared
/// specimen, iOS uses tappable Form rows — each carries its own live specimen
/// on the right and a checkmark when selected, which reads more natively here.
struct AppearanceSettingsSection: View {
    @Environment(iOSSettingsStore.self) private var settings
    @Environment(HapticsClient.self) private var haptics

    var body: some View {
        @Bindable var settings = settings

        Section(String(localized: "App Typeface")) {
            ForEach(AppFontPreference.allCases) { preference in
                AppearanceOptionRow(
                    title: typefaceTitle(preference),
                    description: typefaceDescription(preference),
                    isSelected: settings.fontPreference == preference,
                    specimen: { TypefaceSpecimen(typeface: preference) }
                ) {
                    settings.fontPreference = preference
                    haptics.fire(.selection)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: settings.fontPreference)

        Section(String(localized: "Preview Spacing")) {
            ForEach(PreviewFontPreference.allCases) { style in
                AppearanceOptionRow(
                    title: spacingTitle(style),
                    description: spacingDescription(style),
                    isSelected: settings.previewFontPreference == style,
                    specimen: {
                        SpacingSpecimen(style: style, typeface: settings.fontPreference)
                    }
                ) {
                    settings.previewFontPreference = style
                    haptics.fire(.selection)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: settings.previewFontPreference)
        .animation(.easeInOut(duration: 0.18), value: settings.fontPreference)
    }

    private func typefaceTitle(_ preference: AppFontPreference) -> String {
        switch preference {
        case .iosevkaCharon: return String(localized: "Iosevka Charon")
        case .system: return String(localized: "System")
        }
    }

    private func typefaceDescription(_ preference: AppFontPreference) -> String {
        switch preference {
        case .iosevkaCharon: return String(localized: "ClipKitty's dense, distinctive typeface.")
        case .system: return String(localized: "The native system font.")
        }
    }

    private func spacingTitle(_ style: PreviewFontPreference) -> String {
        switch style {
        case .coding: return String(localized: "Monospace")
        case .proportional: return String(localized: "Proportional")
        }
    }

    private func spacingDescription(_ style: PreviewFontPreference) -> String {
        switch style {
        case .coding: return String(localized: "Even-width characters; columns line up. Great for code.")
        case .proportional: return String(localized: "Natural spacing; easier to read. Good for prose.")
        }
    }
}

// MARK: - Option row

/// A single tappable settings row: title + description on the left, a live
/// specimen of the option's font on the right, and a checkmark when selected.
private struct AppearanceOptionRow<Specimen: View>: View {
    let title: String
    let description: String
    let isSelected: Bool
    @ViewBuilder let specimen: () -> Specimen
    let onSelect: () -> Void

    var body: some View {
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

                specimen()
                    .foregroundStyle(.secondary)

                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Specimens

/// Renders "Aa Gg" in the candidate UI typeface so each row previews itself.
private struct TypefaceSpecimen: View {
    let typeface: AppFontPreference

    var body: some View {
        Text(verbatim: "Aa Gg")
            .font(AppFont.ui(typeface, size: 17, weight: .medium))
            .lineLimit(1)
    }
}

/// Renders a digit/letter sample in the candidate preview spacing so the
/// monospace-vs-proportional difference is visible at a glance.
private struct SpacingSpecimen: View {
    let style: PreviewFontPreference
    let typeface: AppFontPreference

    var body: some View {
        Text(verbatim: "il 012")
            .font(AppFont.preview(typeface: typeface, style: style, size: 15, weight: .medium))
            .lineLimit(1)
    }
}
