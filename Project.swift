import ProjectDescription

// MARK: - Capability Model

/// Each capability maps to a compile condition and controls what code is included.
/// Variants declare the set of capabilities they support; everything else is derived.
enum Capability: String, CaseIterable {
    case syntheticPaste // ENABLE_SYNTHETIC_PASTE
    case fileClipboardItems // ENABLE_FILE_CLIPBOARD_ITEMS
    case linkPreviews // ENABLE_LINK_PREVIEWS
    case iCloudSync // ENABLE_ICLOUD_SYNC
    case sparkleUpdates // ENABLE_SPARKLE_UPDATES
    case buildAttestationLink // ENABLE_BUILD_ATTESTATION_LINK
    case hardened // CLIPKITTY_HARDENED

    var compileCondition: String {
        switch self {
        case .syntheticPaste: return "ENABLE_SYNTHETIC_PASTE"
        case .fileClipboardItems: return "ENABLE_FILE_CLIPBOARD_ITEMS"
        case .linkPreviews: return "ENABLE_LINK_PREVIEWS"
        case .iCloudSync: return "ENABLE_ICLOUD_SYNC"
        case .sparkleUpdates: return "ENABLE_SPARKLE_UPDATES"
        case .buildAttestationLink: return "ENABLE_BUILD_ATTESTATION_LINK"
        case .hardened: return "CLIPKITTY_HARDENED"
        }
    }
}

// MARK: - Build Variant Model

// All macOS build configuration is derived from this enum via exhaustive switches.
// To add a new variant, add a case here and the compiler will guide you through
// every property that needs a value.

enum MacBuildVariant: CaseIterable {
    case debug
    case release
    case sparkle
    case appStore
    case hardened

    // MARK: Core Identity

    var configurationName: ConfigurationName {
        switch self {
        case .debug: return "Debug"
        case .release: return "Release"
        case .sparkle: return .configuration("SparkleRelease")
        case .appStore: return .configuration("AppStore")
        case .hardened: return .configuration("Hardened")
        }
    }

    var isRelease: Bool {
        switch self {
        case .debug: return false
        case .release, .sparkle, .appStore, .hardened: return true
        }
    }

    var buildChannel: String {
        switch self {
        case .debug: return "Debug"
        case .release: return "Release"
        case .sparkle: return "Sparkle"
        case .appStore: return "AppStore"
        case .hardened: return "Hardened"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .hardened: return "com.eviljuliette.clipkitty.hardened"
        case .debug, .release, .sparkle, .appStore: return "com.eviljuliette.clipkitty"
        }
    }

    var displayName: String {
        switch self {
        case .hardened: return "ClipKitty Hardened"
        case .debug, .release, .sparkle, .appStore: return "ClipKitty"
        }
    }

    var entitlementsPath: String {
        switch self {
        case .debug: return "Sources/MacApp/ClipKitty.debug.entitlements"
        case .release: return "Sources/MacApp/ClipKitty.oss.entitlements"
        case .sparkle: return "Sources/MacApp/ClipKitty.sparkle.entitlements"
        case .appStore: return "Sources/MacApp/ClipKitty.appstore.entitlements"
        case .hardened: return "Sources/MacApp/ClipKitty.hardened.entitlements"
        }
    }

    // MARK: Capabilities — the single source of truth for what each variant can do

    var capabilities: Set<Capability> {
        switch self {
        case .debug: return [.syntheticPaste, .fileClipboardItems, .linkPreviews, .iCloudSync, .buildAttestationLink]
        case .release: return [.syntheticPaste, .fileClipboardItems, .linkPreviews, .iCloudSync, .buildAttestationLink]
        case .sparkle: return [.syntheticPaste, .fileClipboardItems, .linkPreviews, .iCloudSync, .buildAttestationLink, .sparkleUpdates]
        case .appStore: return [.syntheticPaste, .fileClipboardItems, .linkPreviews, .iCloudSync, .buildAttestationLink]
        case .hardened: return [.syntheticPaste, .hardened]
        }
    }

    // MARK: Compilation Conditions (derived from capabilities, per target layer)

    /// Flags for the main macOS app target (all capabilities)
    var macAppCompilationConditions: String {
        capabilities.map(\.compileCondition).sorted().joined(separator: " ")
    }

    /// Flags for ClipKittyAppleServices (cross-platform: sync + link previews).
    /// Link previews are always enabled here because the iOS app unconditionally
    /// uses LinkPreviewView; the hardened macOS app simply doesn't call it.
    var appleServicesCompilationConditions: String {
        var flags = capabilities.intersection([.iCloudSync])
        flags.insert(.linkPreviews)
        return flags.map(\.compileCondition).sorted().joined(separator: " ")
    }

    /// Flags for ClipKittyMacPlatform (file clipboard + synthetic paste)
    var macPlatformCompilationConditions: String {
        capabilities.intersection([.syntheticPaste, .fileClipboardItems])
            .map(\.compileCondition).sorted().joined(separator: " ")
    }

    /// Flags for ClipKittyShared (cross-platform: link previews)
    var sharedCompilationConditions: String {
        capabilities.intersection([.linkPreviews])
            .map(\.compileCondition).sorted().joined(separator: " ")
    }

    // MARK: Target Name — which macOS app target this variant builds

    /// The Sparkle variant builds its own target (ClipKittySpark) that depends on
    /// SparkleUpdater. All other variants build the plain ClipKitty target which
    /// has no Sparkle in its dependency graph at all.
    var macAppTargetName: String {
        switch self {
        case .sparkle: return "ClipKittySpark"
        case .debug, .release, .appStore, .hardened: return "ClipKitty"
        }
    }

    /// Whether this variant requires SparkleUpdater in the target dependency graph.
    var requiresSparkle: Bool {
        capabilities.contains(.sparkleUpdates)
    }

    /// Additional target-level dependencies for this variant's target.
    var additionalTargetDependencies: [TargetDependency] {
        if requiresSparkle {
            return [.external(name: "SparkleUpdater")]
        }
        return []
    }

    /// Additional target-level base build settings (e.g. Sparkle feed config).
    var additionalTargetBaseSettings: SettingsDictionary {
        if requiresSparkle {
            return [
                "PRODUCT_NAME": "ClipKitty",
                "SPARKLE_FEED_URL": "https://jul-sh.github.io/clipkitty/appcast.xml",
                "SPARKLE_PUBLIC_KEY": "9VqfSPPY2Gr8QTYDLa99yJXAFWnHw5aybSbKaYDyCq0=",
                "SPARKLE_AUTO_CHECK": "YES",
                "SPARKLE_AUTO_UPDATE": "YES",
                "SPARKLE_INSTALLER_SERVICE": "YES",
            ]
        }
        return [:]
    }

    /// Additional Info.plist entries for this variant's target.
    var additionalInfoPlistEntries: [String: Plist.Value] {
        if requiresSparkle {
            return [
                "SUFeedURL": "$(SPARKLE_FEED_URL)",
                "SUPublicEDKey": "$(SPARKLE_PUBLIC_KEY)",
                "SUEnableAutomaticChecks": "$(SPARKLE_AUTO_CHECK)",
                "SUAutomaticallyUpdate": "$(SPARKLE_AUTO_UPDATE)",
                "SUEnableInstallerLauncherService": "$(SPARKLE_INSTALLER_SERVICE)",
            ]
        }
        return [:]
    }

    // MARK: Scheme — derived from the variant

    /// Scheme name. nil means this variant uses the main "ClipKitty" scheme.
    var schemeName: String? {
        switch self {
        case .debug: return nil // Uses the main "ClipKitty" scheme
        case .release: return nil // Built via main scheme with CONFIGURATION=Release
        case .sparkle: return "ClipKittySpark" // Separate target with Sparkle dependency
        case .appStore: return "ClipKitty-AppStore"
        case .hardened: return "ClipKitty-Hardened"
        }
    }

    /// Generate a dedicated scheme for this variant, if it needs one.
    func scheme() -> Scheme? {
        guard let name = schemeName else { return nil }
        let target = macAppTargetName
        return .scheme(
            name: name,
            shared: true,
            buildAction: .buildAction(
                targets: [.target(target)],
                preActions: [rustPreBuildAction(target: target)]
            ),
            runAction: .runAction(
                configuration: configurationName,
                executable: .target(target)
            ),
            archiveAction: .archiveAction(configuration: configurationName)
        )
    }

    // MARK: Configuration Builders

    func projectConfiguration() -> Configuration {
        if isRelease {
            return .release(name: configurationName, settings: [:])
        } else {
            return .debug(name: configurationName, settings: [:])
        }
    }

    func macAppConfiguration() -> Configuration {
        let settings: SettingsDictionary = [
            "CODE_SIGN_STYLE": "Automatic",
            "CODE_SIGN_IDENTITY": "Apple Development",
            "CODE_SIGN_ENTITLEMENTS": .string(entitlementsPath),
            "PRODUCT_BUNDLE_IDENTIFIER": .string(bundleIdentifier),
            "CK_BUNDLE_IDENTIFIER": .string(bundleIdentifier),
            "CK_BUILD_CHANNEL": .string(buildChannel),
            "CK_DISPLAY_NAME": .string(displayName),
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": .string(macAppCompilationConditions),
        ]

        if isRelease {
            return .release(name: configurationName, settings: settings)
        } else {
            return .debug(name: configurationName, settings: settings)
        }
    }

    func appleServicesConfiguration() -> Configuration {
        let conditions = appleServicesCompilationConditions
        let settings: SettingsDictionary = conditions.isEmpty ? [:] : [
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": .string(conditions),
        ]
        if isRelease {
            return .release(name: configurationName, settings: settings)
        } else {
            return .debug(name: configurationName, settings: settings)
        }
    }

    func sharedConfiguration() -> Configuration {
        let conditions = sharedCompilationConditions
        let settings: SettingsDictionary = conditions.isEmpty ? [:] : [
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": .string(conditions),
        ]
        if isRelease {
            return .release(name: configurationName, settings: settings)
        } else {
            return .debug(name: configurationName, settings: settings)
        }
    }

    func macPlatformConfiguration() -> Configuration {
        let conditions = macPlatformCompilationConditions
        let settings: SettingsDictionary = conditions.isEmpty ? [:] : [
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": .string(conditions),
        ]
        if isRelease {
            return .release(name: configurationName, settings: settings)
        } else {
            return .debug(name: configurationName, settings: settings)
        }
    }

    func uiTestsConfiguration() -> Configuration {
        let settings: SettingsDictionary = [
            "CODE_SIGN_STYLE": "Manual",
            "CODE_SIGN_IDENTITY": "Developer ID Application",
            "DEVELOPMENT_TEAM": "ANBBV7LQ2P",
        ]
        if isRelease {
            return .release(name: configurationName, settings: settings)
        } else {
            return .debug(name: configurationName, settings: settings)
        }
    }
}

// MARK: - iOS Build Variant Model

// iOS variants are simpler: Debug, Release, SparkleRelease (no-op), AppStore.
// Hardened is macOS-only but must be declared so SPM dependencies build.

enum IOSBuildVariant: CaseIterable {
    case debug
    case release
    case sparkle // no-op config (maps to Release settings)
    case appStore
    case hardened // no-op config for SPM compat

    var configurationName: ConfigurationName {
        switch self {
        case .debug: return "Debug"
        case .release: return "Release"
        case .sparkle: return .configuration("SparkleRelease")
        case .appStore: return .configuration("AppStore")
        case .hardened: return .configuration("Hardened")
        }
    }

    var isRelease: Bool {
        switch self {
        case .debug: return false
        case .release, .sparkle, .appStore, .hardened: return true
        }
    }

    /// iOS always gets sync and link previews (no hardened iOS variant)
    var compilationConditions: String {
        switch self {
        case .debug, .release:
            return "ENABLE_ICLOUD_SYNC ENABLE_LINK_PREVIEWS"
        case .sparkle, .hardened:
            return "" // no-op configs
        case .appStore:
            return "ENABLE_ICLOUD_SYNC ENABLE_LINK_PREVIEWS"
        }
    }

    func iOSAppConfiguration() -> Configuration {
        let settings: SettingsDictionary
        switch self {
        case .debug:
            settings = [
                "CODE_SIGN_STYLE": "Automatic",
                "CODE_SIGN_IDENTITY": "Apple Development",
                "CODE_SIGN_ENTITLEMENTS": "Sources/iOSApp/ClipKittyiOS.entitlements",
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS": .string(compilationConditions),
            ]
        case .release:
            settings = [
                "CODE_SIGN_STYLE": "Automatic",
                "CODE_SIGN_IDENTITY": "Apple Development",
                "CODE_SIGN_ENTITLEMENTS": "Sources/iOSApp/ClipKittyiOS.entitlements",
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS": .string(compilationConditions),
            ]
        case .sparkle, .hardened:
            settings = [:]
        case .appStore:
            settings = [
                "CODE_SIGN_STYLE": "Manual",
                "CODE_SIGN_IDENTITY": "Apple Distribution",
                "CODE_SIGN_ENTITLEMENTS": "Sources/iOSApp/ClipKittyiOS.appstore.entitlements",
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS": .string(compilationConditions),
                "PROVISIONING_PROFILE_SPECIFIER": "ClipKitty iOS AppStore",
            ]
        }

        if isRelease {
            return .release(name: configurationName, settings: settings)
        } else {
            return .debug(name: configurationName, settings: settings)
        }
    }

    func shareExtensionConfiguration() -> Configuration {
        let settings: SettingsDictionary
        switch self {
        case .debug:
            settings = [
                "CODE_SIGN_STYLE": "Automatic",
                "CODE_SIGN_IDENTITY": "Apple Development",
                "CODE_SIGN_ENTITLEMENTS": "Sources/ShareExtension/ClipKittyShare.entitlements",
            ]
        case .release:
            settings = [
                "CODE_SIGN_STYLE": "Automatic",
                "CODE_SIGN_IDENTITY": "Apple Development",
                "CODE_SIGN_ENTITLEMENTS": "Sources/ShareExtension/ClipKittyShare.entitlements",
            ]
        case .sparkle, .hardened:
            settings = [:]
        case .appStore:
            settings = [
                "CODE_SIGN_STYLE": "Manual",
                "CODE_SIGN_IDENTITY": "Apple Distribution",
                "CODE_SIGN_ENTITLEMENTS": "Sources/ShareExtension/ClipKittyShare.entitlements",
                "PROVISIONING_PROFILE_SPECIFIER": "ClipKitty Share AppStore",
            ]
        }

        if isRelease {
            return .release(name: configurationName, settings: settings)
        } else {
            return .debug(name: configurationName, settings: settings)
        }
    }
}

// MARK: - Shared Scheme Components

/// Rust pre-build action shared across all macOS app schemes.
/// Detects purr/ changes via git tree hash and rebuilds bindings when needed.
///
/// When CLIPKITTY_SKIP_RUST_PREBUILD=1 is set, the script is a no-op: this is
/// the contract with the Nix flake, which supplies Rust bridge artifacts into
/// the staged source tree before invoking xcodebuild and doesn't want
/// Xcode to try to regenerate them.
private let rustPreBuildScript = """
if [ "${CLIPKITTY_SKIP_RUST_PREBUILD:-0}" = "1" ]; then
    echo "CLIPKITTY_SKIP_RUST_PREBUILD=1 — Rust bridge already supplied, skipping."
    exit 0
fi

# Use git tree hash to detect purr/ changes (fast, handles branches/rebases)
cd "$PROJECT_DIR"
MARKER=".make/rust-tree-hash"
LIB="Sources/ClipKittyRust/libpurr.a"
CURRENT_HASH=$(git rev-parse HEAD:purr 2>/dev/null || echo "unknown")
STORED_HASH=$(cat "$MARKER" 2>/dev/null || echo "none")

if [ -f "$LIB" ] && [ "$CURRENT_HASH" = "$STORED_HASH" ]; then
    echo "Rust bindings up to date (tree hash: ${CURRENT_HASH:0:8}), skipping."
    exit 0
fi

echo "Rust changed: $STORED_HASH -> $CURRENT_HASH"
export CARGO_TARGET_DIR="$(dirname "$(realpath "$(git rev-parse --git-common-dir)")")/target"
if [ -z "${IN_NIX_SHELL:-}" ]; then
    nix develop --no-update-lock-file --experimental-features 'nix-command flakes' "$PROJECT_DIR#default" --command bash -c "cd purr && MACOSX_DEPLOYMENT_TARGET=14.0 cargo run ${LOCKED:+--locked} --release --bin generate-bindings"
else
    (cd purr && MACOSX_DEPLOYMENT_TARGET=14.0 cargo run ${LOCKED:+--locked} --release --bin generate-bindings)
fi
mkdir -p .make && echo "$CURRENT_HASH" > "$MARKER"
"""

/// Creates a Rust pre-build execution action targeting the given app target.
func rustPreBuildAction(target: String) -> ExecutionAction {
    .executionAction(
        title: "Build Rust Core",
        scriptText: rustPreBuildScript,
        target: .target(target)
    )
}

// MARK: - macOS App Target Factory

/// Shared Info.plist entries for all macOS app targets.
private let macAppInfoPlist: [String: Plist.Value] = [
    "CFBundleDisplayName": "$(CK_DISPLAY_NAME)",
    "CFBundleIdentifier": "$(CK_BUNDLE_IDENTIFIER)",
    "CFBundleIconName": "AppIcon",
    "CFBundleIconFile": "AppIcon",
    "CFBundleDevelopmentRegion": "en",
    "CFBundleShortVersionString": "$(MARKETING_VERSION)",
    "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    "CKBuildChannel": "$(CK_BUILD_CHANNEL)",
    "ITSAppUsesNonExemptEncryption": false,
    "LSApplicationCategoryType": "public.app-category.utilities",
    "LSMinimumSystemVersion": "14.0",
    "NSHumanReadableCopyright": "Copyright © 2025 ClipKitty. All rights reserved.",
]

/// Shared base build settings for all macOS app targets.
private let macAppBaseSettings: SettingsDictionary = [
    "OTHER_LDFLAGS": .array(["$(inherited)", "-lpurr"]),
    "LIBRARY_SEARCH_PATHS": .array(["$(inherited)", "$(PROJECT_DIR)/Sources/ClipKittyRust"]),
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
    "DEVELOPMENT_TEAM": "ANBBV7LQ2P",
]

/// Shared source and resource paths for all macOS app targets.
private let macAppSources: SourceFilesList = ["Sources/MacApp/**"]
private let macAppResources: ResourceFileElements = [
    .folderReference(path: "Sources/MacApp/Resources/Fonts"),
    "Sources/MacApp/Resources/menu-bar.svg",
    "Sources/MacApp/Resources/Localizable.xcstrings",
    "Sources/MacApp/Assets.xcassets",
    "Sources/MacApp/PrivacyInfo.xcprivacy",
]

/// Shared dependencies for all macOS app targets (no Sparkle).
private let macAppCoreDependencies: [TargetDependency] = [
    .target(name: "ClipKittyRust"),
    .target(name: "ClipKittyShared"),
    .target(name: "ClipKittyAppleServices"),
    .target(name: "ClipKittyMacPlatform"),
    .target(name: "ClipKittyShortcuts"),
    .sdk(name: "SystemConfiguration", type: .framework),
    .external(name: "STTextKitPlus"),
]

/// Creates macOS app targets, one per distinct `macAppTargetName`.
///
/// Variants are grouped by target name. Each group produces one Tuist target
/// whose configurations come from its member variants. This is how Sparkle
/// stays out of non-Sparkle targets: the enum's `requiresSparkle` /
/// `additionalTargetDependencies` / `additionalTargetBaseSettings` drive
/// everything — no hardcoded Sparkle knowledge lives here.
func makeMacAppTargets() -> [Target] {
    // Group variants by target name, preserving allCases order
    var groups: [(name: String, variants: [MacBuildVariant])] = []
    for variant in MacBuildVariant.allCases {
        let name = variant.macAppTargetName
        if let idx = groups.firstIndex(where: { $0.name == name }) {
            groups[idx].variants.append(variant)
        } else {
            groups.append((name: name, variants: [variant]))
        }
    }

    return groups.map { group in
        let representative = group.variants[0]

        var infoPlist = macAppInfoPlist
        for (key, value) in representative.additionalInfoPlistEntries {
            infoPlist[key] = value
        }

        var baseSettings = macAppBaseSettings
        for (key, value) in representative.additionalTargetBaseSettings {
            baseSettings[key] = value
        }

        // Every target must define ALL project-level configurations so Xcode
        // can resolve build settings for any configuration name. For variants
        // outside this group, emit a placeholder configuration with empty
        // settings (inherits project defaults).
        let configurations = MacBuildVariant.allCases.map { variant -> Configuration in
            if group.variants.contains(where: { $0 == variant }) {
                return variant.macAppConfiguration()
            }
            return variant.isRelease
                ? .release(name: variant.configurationName, settings: [:])
                : .debug(name: variant.configurationName, settings: [:])
        }

        return Target.target(
            name: group.name,
            destinations: .macOS,
            product: .app,
            bundleId: "com.eviljuliette.clipkitty",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: infoPlist),
            sources: macAppSources,
            resources: macAppResources,
            dependencies: macAppCoreDependencies + representative.additionalTargetDependencies,
            settings: .settings(
                base: baseSettings,
                configurations: configurations
            )
        )
    }
}

// MARK: - Build Configurations

let configurations: [Configuration] = MacBuildVariant.allCases.map { $0.projectConfiguration() }

// MARK: - Project

let project = Project(
    name: "ClipKitty",
    settings: .settings(
        base: [
            "MARKETING_VERSION": "1.13.0",
            "CURRENT_PROJECT_VERSION": "1",
        ],
        configurations: configurations,
        defaultSettings: .recommended
    ),
    targets: [
        // MARK: ClipKittyRustFFI — C library (FFI bridge to Rust)

        // SYNC: Library name must match purr/Cargo.toml [lib] name = "purr"
        // SYNC: Header comes from purr/src/bin/generate_bindings.rs → purrFFI.h
        .target(
            name: "ClipKittyRustFFI",
            destinations: [.mac, .iPhone],
            product: .staticLibrary,
            bundleId: "com.eviljuliette.clipkitty.rustffi",
            deploymentTargets: .multiplatform(iOS: "26.0", macOS: "14.0"),
            sources: ["Sources/ClipKittyRust/ClipKittyRustFFI.c"],
            headers: .headers(
                project: ["Sources/ClipKittyRust/purrFFI.h"]
            ),
            settings: .settings(
                base: [
                    "HEADER_SEARCH_PATHS": .array(["$(inherited)", "$(PROJECT_DIR)/Sources/ClipKittyRust"]),
                    "MODULEMAP_FILE": "$(PROJECT_DIR)/Sources/ClipKittyRust/module.modulemap",
                    "SKIP_INSTALL": "YES",
                ]
            )
        ),

        // MARK: ClipKittyRust — Swift wrapper (UniFFI-generated + manual)

        .target(
            name: "ClipKittyRust",
            destinations: [.mac, .iPhone],
            product: .staticLibrary,
            bundleId: "com.eviljuliette.clipkitty.rust",
            deploymentTargets: .multiplatform(iOS: "26.0", macOS: "14.0"),
            sources: ["Sources/ClipKittyRustWrapper/**"],
            dependencies: [
                .target(name: "ClipKittyRustFFI"),
            ],
            settings: .settings(
                base: [
                    // UniFFI-generated code not yet compatible with Swift 6 strict concurrency
                    "SWIFT_VERSION": "5.0",
                    "SKIP_INSTALL": "YES",
                ]
            )
        ),

        // MARK: ClipKittyShared — Cross-platform Swift library (no AppKit)

        .target(
            name: "ClipKittyShared",
            destinations: [.mac, .iPhone],
            product: .staticLibrary,
            bundleId: "com.eviljuliette.clipkitty.shared",
            deploymentTargets: .multiplatform(iOS: "26.0", macOS: "14.0"),
            sources: ["Sources/Shared/**"],
            dependencies: [
                .target(name: "ClipKittyRust"),
            ],
            settings: .settings(
                base: [
                    "SKIP_INSTALL": "YES",
                ],
                configurations: MacBuildVariant.allCases.map { $0.sharedConfiguration() }
            )
        ),

        // MARK: ClipKittyAppleServices — Cross-Apple services (no AppKit)

        .target(
            name: "ClipKittyAppleServices",
            destinations: [.mac, .iPhone],
            product: .staticLibrary,
            bundleId: "com.eviljuliette.clipkitty.appleservices",
            deploymentTargets: .multiplatform(iOS: "26.0", macOS: "14.0"),
            sources: ["Sources/AppleServices/**"],
            dependencies: [
                .target(name: "ClipKittyRust"),
                .target(name: "ClipKittyShared"),
            ],
            settings: .settings(
                base: [
                    "SKIP_INSTALL": "YES",
                ],
                configurations: MacBuildVariant.allCases.map { $0.appleServicesConfiguration() }
            )
        ),

        // MARK: ClipKittyMacPlatform — macOS-only platform integrations

        .target(
            name: "ClipKittyMacPlatform",
            destinations: .macOS,
            product: .staticLibrary,
            bundleId: "com.eviljuliette.clipkitty.macplatform",
            deploymentTargets: .macOS("14.0"),
            sources: ["Sources/MacPlatform/**"],
            dependencies: [
                .target(name: "ClipKittyShared"),
            ],
            settings: .settings(
                base: [
                    "SKIP_INSTALL": "YES",
                ],
                configurations: MacBuildVariant.allCases.map { $0.macPlatformConfiguration() }
            )
        ),

        // MARK: ClipKittyShortcuts — App Intents exposed to Apple Shortcuts

        .target(
            name: "ClipKittyShortcuts",
            destinations: [.mac, .iPhone],
            product: .staticLibrary,
            bundleId: "com.eviljuliette.clipkitty.shortcuts",
            deploymentTargets: .multiplatform(iOS: "26.0", macOS: "14.0"),
            sources: ["Sources/Shortcuts/**"],
            dependencies: [
                .target(name: "ClipKittyRust"),
                .target(name: "ClipKittyShared"),
            ],
            settings: .settings(
                base: [
                    "SKIP_INSTALL": "YES",
                ]
            )
        ),

    ] + makeMacAppTargets() + [
        // MARK: ClipKittyTests — Unit tests

        .target(
            name: "ClipKittyTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.eviljuliette.clipkitty.tests",
            deploymentTargets: .macOS("14.0"),
            sources: .sourceFilesList(globs: [
                .glob("Tests/**", excluding: ["Tests/UITests/**", "Tests/iOSTests/**"]),
            ]),
            dependencies: [
                .target(name: "ClipKitty"),
                .target(name: "ClipKittyRust"),
                .target(name: "ClipKittyShared"),
                .target(name: "ClipKittyAppleServices"),
                .target(name: "ClipKittyMacPlatform"),
                .target(name: "ClipKittyShortcuts"),
            ],
            settings: .settings(
                base: [
                    "OTHER_LDFLAGS": .array(["$(inherited)", "-lpurr"]),
                    "LIBRARY_SEARCH_PATHS": .array(["$(inherited)", "$(PROJECT_DIR)/Sources/ClipKittyRust"]),
                ]
            )
        ),

        // MARK: ClipKittyUITests — UI tests

        // Debug runs should sign locally so local UI test runs can execute without
        // requiring a Developer ID identity. Non-debug builds can still opt into
        // Developer ID signing for stable TCC behavior across rebuilds.
        .target(
            name: "ClipKittyUITests",
            destinations: .macOS,
            product: .uiTests,
            bundleId: "com.clipkitty.UITests",
            deploymentTargets: .macOS("14.0"),
            sources: ["Tests/UITests/**"],
            entitlements: .file(path: "Tests/UITests/ClipKittyUITests.entitlements"),
            dependencies: [
                .target(name: "ClipKitty"),
            ],
            settings: .settings(
                configurations: MacBuildVariant.allCases.map { $0.uiTestsConfiguration() }
            ),
            environmentVariables: [
                "CLIPKITTY_APP_PATH": "$(BUILT_PRODUCTS_DIR)/ClipKitty.app",
            ]
        ),

        // MARK: ClipKittyiOS — iPhone and iPad app

        .target(
            name: "ClipKittyiOS",
            destinations: [.iPhone, .iPad],
            product: .app,
            bundleId: "com.eviljuliette.clipkitty",
            deploymentTargets: .iOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "ClipKitty",
                "CFBundleIconName": "AppIcon",
                "CFBundleDevelopmentRegion": "en",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "ITSAppUsesNonExemptEncryption": false,
                "LSApplicationCategoryType": "public.app-category.utilities",
                "NSHumanReadableCopyright": "Copyright © 2025 ClipKitty. All rights reserved.",
                "UILaunchScreen": ["UIColorName": ""],
            ]),
            sources: ["Sources/iOSApp/**"],
            resources: [
                "AppIcon.icon",
                "Sources/iOSApp/Resources/Fonts/**",
                "Sources/iOSApp/Resources/Localizable.xcstrings",
                "Sources/iOSApp/PrivacyInfo.xcprivacy",
            ],
            dependencies: [
                .target(name: "ClipKittyRust"),
                .target(name: "ClipKittyShared"),
                .target(name: "ClipKittyAppleServices"),
                .target(name: "ClipKittyShortcuts"),
                .target(name: "ClipKittyShare"),
            ],
            settings: .settings(
                base: [
                    "OTHER_LDFLAGS": .array(["$(inherited)", "-lpurr"]),
                    "LIBRARY_SEARCH_PATHS[sdk=iphoneos*]": .array([
                        "$(inherited)",
                        "$(PROJECT_DIR)/Sources/ClipKittyRust/ios-device",
                    ]),
                    "LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]": .array([
                        "$(inherited)",
                        "$(PROJECT_DIR)/Sources/ClipKittyRust/ios-simulator",
                    ]),
                    "DEVELOPMENT_TEAM": "ANBBV7LQ2P",
                    "SWIFT_EMIT_LOC_STRINGS": "YES",
                    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
                ],
                configurations: IOSBuildVariant.allCases.map { $0.iOSAppConfiguration() }
            )
        ),

        // MARK: ClipKittyShare — iOS Share Extension

        .target(
            name: "ClipKittyShare",
            destinations: [.iPhone, .iPad],
            product: .appExtension,
            bundleId: "com.eviljuliette.clipkitty.share",
            deploymentTargets: .iOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "ClipKitty",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "NSExtension": [
                    "NSExtensionPointIdentifier": "com.apple.share-services",
                    "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).ShareViewController",
                    "NSExtensionAttributes": [
                        "NSExtensionActivationRule": [
                            "NSExtensionActivationSupportsText": true,
                            "NSExtensionActivationSupportsWebURLWithMaxCount": 1,
                            "NSExtensionActivationSupportsImageWithMaxCount": 1,
                        ],
                    ],
                ],
            ]),
            sources: ["Sources/ShareExtension/**"],
            dependencies: [
                .target(name: "ClipKittyRust"),
                .target(name: "ClipKittyShared"),
            ],
            settings: .settings(
                base: [
                    "OTHER_LDFLAGS": .array(["$(inherited)", "-lpurr"]),
                    "LIBRARY_SEARCH_PATHS[sdk=iphoneos*]": .array([
                        "$(inherited)",
                        "$(PROJECT_DIR)/Sources/ClipKittyRust/ios-device",
                    ]),
                    "LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]": .array([
                        "$(inherited)",
                        "$(PROJECT_DIR)/Sources/ClipKittyRust/ios-simulator",
                    ]),
                    "DEVELOPMENT_TEAM": "ANBBV7LQ2P",
                ],
                configurations: IOSBuildVariant.allCases.map { $0.shareExtensionConfiguration() }
            )
        ),

        // MARK: ClipKittyiOSTests — iOS integration tests

        .target(
            name: "ClipKittyiOSTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "com.eviljuliette.clipkitty.tests.ios",
            deploymentTargets: .iOS("26.0"),
            sources: ["Tests/iOSTests/**"],
            dependencies: [
                .target(name: "ClipKittyiOS"),
                .target(name: "ClipKittyRust"),
                .target(name: "ClipKittyShared"),
                .target(name: "ClipKittyAppleServices"),
                .target(name: "ClipKittyShortcuts"),
            ],
            settings: .settings(
                base: [
                    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "ENABLE_ICLOUD_SYNC ENABLE_LINK_PREVIEWS",
                    "OTHER_LDFLAGS": .array(["$(inherited)", "-lpurr"]),
                    "LIBRARY_SEARCH_PATHS[sdk=iphoneos*]": .array([
                        "$(inherited)",
                        "$(PROJECT_DIR)/Sources/ClipKittyRust/ios-device",
                    ]),
                    "LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]": .array([
                        "$(inherited)",
                        "$(PROJECT_DIR)/Sources/ClipKittyRust/ios-simulator",
                    ]),
                ]
            )
        ),

        // MARK: ClipKittyiOSSmokeTest — compile-time proof that the shared chain builds for iOS

        // This target exists solely to catch macOS leakage into shared/services code.
        // It imports all shared modules and builds for iOS; it is never shipped.
        .target(
            name: "ClipKittyiOSSmokeTest",
            destinations: .iOS,
            product: .app,
            bundleId: "com.eviljuliette.clipkitty.ios-smoke-test",
            deploymentTargets: .iOS("26.0"),
            sources: ["Sources/iOSSmokeTest/**"],
            dependencies: [
                .target(name: "ClipKittyRust"),
                .target(name: "ClipKittyShared"),
                .target(name: "ClipKittyAppleServices"),
                .target(name: "ClipKittyShortcuts"),
            ],
            settings: .settings(
                base: [
                    "OTHER_LDFLAGS": .array(["$(inherited)", "-lpurr"]),
                    "LIBRARY_SEARCH_PATHS[sdk=iphoneos*]": .array([
                        "$(inherited)",
                        "$(PROJECT_DIR)/Sources/ClipKittyRust/ios-device",
                    ]),
                    "LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]": .array([
                        "$(inherited)",
                        "$(PROJECT_DIR)/Sources/ClipKittyRust/ios-simulator",
                    ]),
                    "CODE_SIGNING_ALLOWED": "NO",
                ]
            )
        ),

        // MARK: ClipKittyiOSUITests — iOS UI tests (marketing screenshots)

        .target(
            name: "ClipKittyiOSUITests",
            destinations: .iOS,
            product: .uiTests,
            bundleId: "com.eviljuliette.clipkitty.uitests.ios",
            deploymentTargets: .iOS("26.0"),
            sources: ["Tests/iOSUITests/**"],
            dependencies: [
                .target(name: "ClipKittyiOS"),
            ],
            settings: .settings(
                base: [
                    "DEVELOPMENT_TEAM": "ANBBV7LQ2P",
                ]
            )
        ),
    ],
    schemes: [
        // Main development scheme
        .scheme(
            name: "ClipKitty",
            shared: true,
            buildAction: .buildAction(
                targets: [.target("ClipKitty")],
                preActions: [rustPreBuildAction(target: "ClipKitty")]
            ),
            testAction: .targets(
                [
                    .testableTarget(target: .target("ClipKittyTests")),
                ],
                configuration: "Debug"
            ),
            runAction: .runAction(
                configuration: "Debug",
                executable: .target("ClipKitty")
            )
        ),
    ] + MacBuildVariant.allCases.compactMap { $0.scheme() } + [
        // UI tests scheme
        .scheme(
            name: "ClipKittyUITests",
            shared: true,
            buildAction: .buildAction(
                targets: [
                    .target("ClipKittyUITests"),
                    .target("ClipKitty"),
                ],
                preActions: [rustPreBuildAction(target: "ClipKitty")]
            ),
            testAction: .testPlans(
                [
                    .relativeToRoot("Tests/UITests/ClipKittyUITests.xctestplan"),
                    .relativeToRoot("Tests/UITests/ClipKittyVideoRecording.xctestplan"),
                ],
                configuration: "Debug"
            )
        ),
        // iOS app scheme
        .scheme(
            name: "ClipKittyiOS",
            shared: true,
            buildAction: .buildAction(targets: [
                .target("ClipKittyiOS"),
                .target("ClipKittyShare"),
            ]),
            testAction: .targets(
                [.testableTarget(target: .target("ClipKittyiOSTests"))],
                configuration: "Debug"
            ),
            runAction: .runAction(
                configuration: "Debug",
                executable: .target("ClipKittyiOS")
            )
        ),
        // iOS App Store scheme
        .scheme(
            name: "ClipKittyiOS-AppStore",
            shared: true,
            buildAction: .buildAction(targets: [.target("ClipKittyiOS")]),
            runAction: .runAction(
                configuration: .configuration("AppStore"),
                executable: .target("ClipKittyiOS")
            ),
            archiveAction: .archiveAction(configuration: .configuration("AppStore"))
        ),
        // iOS UI tests scheme (marketing screenshots)
        .scheme(
            name: "ClipKittyiOSUITests",
            shared: true,
            buildAction: .buildAction(
                targets: [
                    .target("ClipKittyiOSUITests"),
                    .target("ClipKittyiOS"),
                ]
            ),
            testAction: .targets(
                [.testableTarget(target: .target("ClipKittyiOSUITests"))],
                configuration: "Debug"
            )
        ),
        // iOS smoke test — builds the shared chain for iOS to catch macOS leakage
        .scheme(
            name: "ClipKittyiOSSmokeTest",
            shared: true,
            buildAction: .buildAction(targets: [.target("ClipKittyiOSSmokeTest")])
        ),
    ],
    additionalFiles: [
        "Sources/MacApp/ClipKitty.oss.entitlements",
        "Sources/MacApp/ClipKitty.debug.entitlements",
        "Sources/MacApp/ClipKitty.sparkle.entitlements",
        "Sources/MacApp/ClipKitty.hardened.entitlements",
    ]
)
