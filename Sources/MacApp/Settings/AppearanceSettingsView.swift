import ClipKittyMacPlatform
import SwiftUI

/// "App Typeface" section body: choose the typeface used across ClipKitty's UI,
/// with a live specimen on the right. Radio rows mirror `PasteItemsSettingView`.
struct AppTypefaceSettingView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        AppearanceOptionGroup(
            options: AppFontPreference.allCases.map { preference in
                .init(
                    isSelected: settings.fontPreference == preference,
                    title: typefaceTitle(preference),
                    description: typefaceDescription(preference),
                    onSelect: { settings.fontPreference = preference }
                )
            },
            preview: { TypefacePreview(typeface: settings.fontPreference) }
        )
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
        case .system: return String(localized: "The native macOS system font.")
        }
    }
}

/// "Preview Character Spacing" section body: choose how text reads in the preview
/// pane — proportional or monospaced — with a live app-mirroring illustration.
struct PreviewSpacingSettingView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        AppearanceOptionGroup(
            options: PreviewFontPreference.allCases.map { style in
                .init(
                    isSelected: settings.previewFontPreference == style,
                    title: spacingTitle(style),
                    description: spacingDescription(style),
                    onSelect: { settings.previewFontPreference = style }
                )
            },
            previewWidth: 108,
            preview: {
                PreviewStylePreview(
                    style: settings.previewFontPreference,
                    typeface: settings.fontPreference
                )
            }
        )
        .animation(.easeInOut(duration: 0.18), value: settings.previewFontPreference)
        .animation(.easeInOut(duration: 0.18), value: settings.fontPreference)
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

// MARK: - Group layout

/// Option rows on the left, a live preview on the right. Headerless — the
/// enclosing `Section` supplies the title.
private struct AppearanceOptionGroup<Preview: View>: View {
    struct Option: Identifiable {
        let id = UUID()
        let isSelected: Bool
        let title: String
        let description: String
        let onSelect: () -> Void
    }

    let options: [Option]
    var previewWidth: CGFloat = 80
    @ViewBuilder let preview: () -> Preview

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(options) { option in
                    AppearanceOptionRow(
                        isSelected: option.isSelected,
                        title: option.title,
                        description: option.description,
                        onSelect: option.onSelect
                    )
                }
            }

            Spacer()

            preview()
                .frame(width: previewWidth, height: 56)
        }
    }
}

/// A single radio-style option row, matching `PasteItemsSettingView`.
private struct AppearanceOptionRow: View {
    let isSelected: Bool
    let title: String
    let description: String
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 8) {
                RadioDot(isSelected: isSelected)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(.primary)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct RadioDot: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.accentColor : Color.clear)
                .frame(width: 14, height: 14)
            Circle()
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 1.5)
                .frame(width: 14, height: 14)
            if isSelected {
                Circle()
                    .fill(Color.white)
                    .frame(width: 5, height: 5)
            }
        }
    }
}

// MARK: - Preview panel chrome

/// Frames live preview content in a soft, inset panel.
private struct PreviewPanel<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

// MARK: - Typeface preview

private struct TypefacePreview: View {
    let typeface: AppFontPreference

    var body: some View {
        PreviewPanel {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Aa")
                    .font(AppFontSpecimen.uiFont(typeface, size: 21, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(verbatim: "Gg 0123")
                    .font(AppFontSpecimen.uiFont(typeface, size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
    }
}

// MARK: - Preview-style preview

/// Mirrors the app's layout: a simplified list row on the left and the preview
/// pane on the right. Only the preview-pane font (monospaced vs proportional)
/// changes between Code and Prose, so that difference is what stands out.
private struct PreviewStylePreview: View {
    let style: PreviewFontPreference
    let typeface: AppFontPreference

    var body: some View {
        HStack(spacing: 0) {
            miniList
                .frame(width: 30)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.primary.opacity(0.05))

            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(width: 1)

            previewPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 5)
                .padding(.trailing, 6)
                .padding(.top, 4)
                .padding(.bottom, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// A simplified clipboard list: solid rows stacked under each other, first selected.
    private var miniList: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(0 ..< 4, id: \.self) { index in
                miniRow(isSelected: index == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func miniRow(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(Color.primary.opacity(isSelected ? 0.28 : 0.16))
            .frame(maxWidth: .infinity)
            .frame(height: 6)
    }

    /// The wide preview pane, with text rendered in the chosen style so the font is visible.
    private var previewPane: some View {
        Text(verbatim: "Aa Gg\n0123 il")
            .font(AppFontSpecimen.previewFont(typeface: typeface, style: style, size: 12, weight: .medium))
            .foregroundStyle(.primary.opacity(0.85))
            .lineLimit(2)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    Form {
        Section("App Typeface") {
            AppTypefaceSettingView()
        }
        Section("Preview Character Spacing") {
            PreviewSpacingSettingView()
        }
    }
    .formStyle(.grouped)
    .frame(width: 560, height: 420)
}
