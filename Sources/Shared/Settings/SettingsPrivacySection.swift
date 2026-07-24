import SwiftUI

/// Link-preview configuration is build-dependent. The enum keeps the missing
/// capability distinct from an available preference instead of pairing a
/// boolean with an optional binding.
public enum SettingsLinkPreviewPreference {
    case unavailable
    case available(Binding<Bool>)
}

/// Common privacy controls with a slot for platform-only filtering options.
public struct SettingsPrivacySection<AdditionalContent: View>: View {
    @Binding private var captureSensitiveClips: Bool
    private let linkPreviews: SettingsLinkPreviewPreference
    private let additionalContent: () -> AdditionalContent

    public init(
        captureSensitiveClips: Binding<Bool>,
        linkPreviews: SettingsLinkPreviewPreference,
        @ViewBuilder additionalContent: @escaping () -> AdditionalContent
    ) {
        _captureSensitiveClips = captureSensitiveClips
        self.linkPreviews = linkPreviews
        self.additionalContent = additionalContent
    }

    public var body: some View {
        Section(String(localized: "Privacy")) {
            SettingsToggleRow(
                title: String(localized: "Capture Sensitive Clips"),
                description: String(
                    localized:
                    "Save clips that apps mark as sensitive, such as passwords and one-time codes."
                ),
                isOn: $captureSensitiveClips
            )

            switch linkPreviews {
            case .unavailable:
                EmptyView()
            case let .available(binding):
                SettingsToggleRow(
                    title: String(localized: "Generate Link Previews"),
                    description: String(
                        localized: "Downloads web content and may trigger tracking links."
                    ),
                    isOn: binding
                )
            }

            additionalContent()
        }
    }
}

/// A toggle row with consistent title and explanatory copy on both platforms.
public struct SettingsToggleRow: View {
    private let title: String
    private let description: String
    @Binding private var isOn: Bool

    public init(title: String, description: String, isOn: Binding<Bool>) {
        self.title = title
        self.description = description
        _isOn = isOn
    }

    public var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
