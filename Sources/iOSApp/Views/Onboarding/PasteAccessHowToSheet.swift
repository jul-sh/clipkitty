import SwiftUI
import UIKit

/// The instructions for granting persistent paste access, shown after the
/// probe raises the system alert.
///
/// This sheet appears whichever way the user answered that alert: "Allow
/// Paste" there grants a single read, not the persistent "Allow" setting
/// Auto-Add needs, so the durable grant always has to be made in Settings.
struct PasteAccessHowToSheet: View {
    let onDismiss: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Text(String(localized: "How to Allow Paste from Other Apps?"))
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 12)

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Close"))
            }
            .padding(.top, 24)
            .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 14) {
                NumberedStep(
                    number: 1,
                    text: String(localized: "Open Settings and tap “Paste from Other Apps”")
                )
                NumberedStep(
                    number: 2,
                    text: String(localized: "Select “Allow”")
                )
            }
            .padding(.top, 18)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, alignment: .leading)

            SettingsRowIllustration()
                .padding(.top, 22)
                .padding(.horizontal, 24)

            Spacer(minLength: 20)

            OnboardingPrimaryButton(title: String(localized: "Open Settings")) {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                openURL(url)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }
}

private struct NumberedStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(number.formatted())
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color(.systemBackground))
                .frame(width: 24, height: 24)
                .background(Color.primary, in: .circle)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 6 }

            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A mock of the Settings row the steps refer to, so the real one is easy to
/// spot after tapping through.
private struct SettingsRowIllustration: View {
    var body: some View {
        VStack(spacing: 10) {
            // Step 1's target: the row inside ClipKitty's Settings page.
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.gray.gradient)
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                    }

                Text(String(localized: "Paste from Other Apps"))
                    .font(.subheadline)

                Spacer()

                Text(String(localized: "Ask"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )

            Image(systemName: "chevron.down")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.tertiary)

            // Step 2's target: the option list that row opens, with "Allow"
            // checked as the user is about to leave it.
            VStack(spacing: 0) {
                OptionRow(title: String(localized: "Ask"), isSelected: false)
                Divider().padding(.leading, 12)
                OptionRow(title: String(localized: "Deny"), isSelected: false)
                Divider().padding(.leading, 12)
                OptionRow(title: String(localized: "Allow"), isSelected: true)
            }
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
        .accessibilityHidden(true)
    }

    private struct OptionRow: View {
        let title: String
        let isSelected: Bool

        var body: some View {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? .primary : .secondary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }
}
