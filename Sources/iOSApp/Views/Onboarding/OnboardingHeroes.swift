import SwiftUI
import UIKit

/// The app icon, drawn from the bundle rather than a duplicated asset so the
/// welcome page always shows the icon the user just tapped.
struct OnboardingAppIcon: View {
    var body: some View {
        Group {
            switch Self.bundleIcon {
            case let .some(icon):
                Image(uiImage: icon)
                    .resizable()
                    .interpolation(.high)
            case .none:
                // A bundle built without a rasterized icon (as in previews and
                // some simulator installs) still needs a plausible hero.
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color.accentColor.gradient)
                    .overlay {
                        Image(systemName: "doc.on.clipboard.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: 128, height: 128)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .accessibilityHidden(true)
    }

    /// The largest icon variant the running bundle actually carries. iOS
    /// records these under `CFBundleIcons`; there is no public API that hands
    /// back the app's own icon image directly.
    private static let bundleIcon: UIImage? = {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let lastName = files.last
        else { return nil }
        return UIImage(named: lastName)
    }()
}

/// Three devices sharing one clipboard: the sync page's hero.
struct OnboardingSyncHero: View {
    var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .bottom, spacing: 22) {
                DeviceGlyph(systemName: "iphone", size: 78)
                DeviceGlyph(systemName: "ipad", size: 96)
                DeviceGlyph(systemName: "macbook", size: 104)
            }

            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.icloud.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
        }
        .accessibilityHidden(true)
    }

    private struct DeviceGlyph: View {
        let systemName: String
        let size: CGFloat

        var body: some View {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .light))
                .foregroundStyle(.primary)
                .symbolRenderingMode(.hierarchical)
                .overlay(alignment: .center) {
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.system(size: size * 0.26))
                        .foregroundStyle(.tint)
                        .offset(y: -size * 0.05)
                }
        }
    }
}

/// A stylized share sheet with ClipKitty's row highlighted: the share page's
/// hero. Built from symbols and shapes rather than a screenshot so it stays
/// correct in both color schemes and every Dynamic Type size.
struct OnboardingShareHero: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.gradient)
                    .frame(width: 38, height: 38)
                    .overlay {
                        Image(systemName: "doc.on.clipboard.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "ClipKitty")
                        .font(.subheadline.weight(.semibold))
                    Text(verbatim: "clipkitty.app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            HStack(spacing: 18) {
                ShareTarget(systemName: "wifi", tint: .blue, title: "AirDrop")
                ShareTarget(systemName: "message.fill", tint: .green, title: "Messages")
                ShareTarget(systemName: "envelope.fill", tint: .blue, title: "Mail")
                ShareTarget(
                    systemName: "doc.on.clipboard.fill",
                    tint: .accentColor,
                    title: "ClipKitty",
                    isHighlighted: true
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        .padding(.horizontal, 26)
        .accessibilityHidden(true)
    }

    private struct ShareTarget: View {
        let systemName: String
        let tint: Color
        let title: String
        var isHighlighted = false

        var body: some View {
            VStack(spacing: 6) {
                Circle()
                    .fill(tint.gradient)
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: systemName)
                            .font(.system(size: 21))
                            .foregroundStyle(.white)
                    }
                    .overlay {
                        if isHighlighted {
                            Circle()
                                .strokeBorder(.tint, lineWidth: 3)
                                .padding(-4)
                        }
                    }

                Text(verbatim: title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// The permission page's hero: a mock of the system paste alert, so the real
/// alert that the probe raises is recognizable when it appears.
struct OnboardingPasteAccessHero: View {
    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text(String(localized: "“ClipKitty” would like to paste from other apps"))
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(String(localized: "Do you want to allow this?"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)

            VStack(spacing: 8) {
                Capsule()
                    .fill(Color(.tertiarySystemFill))
                    .frame(height: 40)
                    .overlay {
                        Text(String(localized: "Don’t Allow"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 40)
                    .overlay {
                        Text(String(localized: "Allow Paste"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
        .accessibilityHidden(true)
    }
}
