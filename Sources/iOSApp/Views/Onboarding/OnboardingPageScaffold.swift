import SwiftUI
import UIKit

/// The shared shape of every onboarding page: a hero area on top, a title and
/// subtitle beneath it, and the page's buttons pinned to the bottom.
///
/// The hero is deliberately given a fixed share of the screen so the title
/// baseline lands in the same place on every page and the copy does not jump
/// as the user advances.
struct OnboardingPageScaffold<Hero: View, Actions: View>: View {
    let title: String
    let message: String
    /// Whether the hero spans the full width and bleeds to the screen edges
    /// (the artwork pages) or sits centered in the text column (the welcome
    /// page's app icon).
    let heroStyle: HeroStyle
    @ViewBuilder let hero: Hero
    @ViewBuilder let actions: Actions

    enum HeroStyle {
        /// Centered in the text column, sized to its content.
        case inline
        /// Fills the top of the screen edge to edge on its own backdrop.
        case fullBleed
    }

    var body: some View {
        VStack(spacing: 0) {
            switch heroStyle {
            case .inline:
                Spacer(minLength: 24)
                hero
                Spacer(minLength: 32)

            case .fullBleed:
                hero
                    .frame(maxWidth: .infinity)
                    .frame(height: 300)
                    .background(Color(.secondarySystemBackground))
                    .clipped()
                // Fixed, not a Spacer: the copy stays anchored just beneath
                // the artwork instead of drifting down the empty middle of a
                // tall screen.
                Spacer()
                    .frame(height: 28)
            }

            VStack(spacing: 12) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(textAlignment)
                    .fixedSize(horizontal: false, vertical: true)

                Text(message)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(textAlignment)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .padding(.horizontal, 28)

            Spacer(minLength: 32)

            VStack(spacing: 12) {
                actions
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    /// The welcome page centers its copy under the icon; the artwork pages
    /// left-align beneath a full-bleed hero, matching the reference flow.
    private var textAlignment: TextAlignment {
        switch heroStyle {
        case .inline: return .center
        case .fullBleed: return .leading
        }
    }

    private var frameAlignment: Alignment {
        switch heroStyle {
        case .inline: return .center
        case .fullBleed: return .leading
        }
    }
}

// MARK: - Buttons

/// The filled primary action at the bottom of a page ("Get Started",
/// "Continue", "Allow Paste from Other Apps").
struct OnboardingPrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }
}

/// The quieter secondary action beneath the primary one ("Enable Later in
/// Settings"), and the non-interactive reassurance capsule on the sync page.
struct OnboardingSecondaryButton: View {
    let title: String
    let systemImage: String?
    let action: (() -> Void)?

    init(title: String, systemImage: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        switch action {
        case let .some(action):
            Button(action: action) {
                label
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(.secondary)

        case .none:
            label
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(Color(.secondarySystemBackground), in: .capsule)
                .foregroundStyle(.secondary)
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
    }
}
