import ProjectDescription

// MARK: - Build Configurations

// Debug:          for development (no Sparkle)
// Release:        for DMG distribution without Sparkle (plain release build)
// SparkleRelease: for DMG distribution with Sparkle auto-updates
// AppStore:       for App Store (no Sparkle, different signing)

let configurations: [Configuration] = [
    .debug(name: "Debug", settings: [:]),
    .release(name: "Release", settings: [:]),
    .release(name: .configuration("SparkleRelease"), settings: [:]),
    .release(name: .configuration("AppStore"), settings: [:]),
]

// MARK: - Project

let project = Project(
    name: "ClipKitty",
    settings: .settings(
        base: [
            "MARKETING_VERSION": "1.12.0",
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
                public: ["Sources/ClipKittyRust/purrFFI.h"]
            ),
            settings: .settings(
                base: [
                    "HEADER_SEARCH_PATHS": .array(["$(inherited)", "$(PROJECT_DIR)/Sources/ClipKittyRust"]),
                    "MODULEMAP_FILE": "$(PROJECT_DIR)/Sources/ClipKittyRust/module.modulemap",
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
            ]
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
                configurations: [
                    .debug(name: "Debug", settings: [
                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "ENABLE_SYNC",
                    ]),
                    .release(name: "Release", settings: [
                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "ENABLE_SYNC",
                    ]),
                    .release(name: .configuration("SparkleRelease"), settings: [
                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "ENABLE_SYNC",
                    ]),
                    .release(name: .configuration("AppStore"), settings: [
                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "ENABLE_SYNC",
                    ]),
                ]
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
            ]
        ),

        // MARK: ClipKitty — macOS app

        .target(
            name: "ClipKitty",
            destinations: .macOS,
            product: .app,
            bundleId: "com.eviljuliette.clipkitty",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "ClipKitty",
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
                // Sparkle keys use build settings so they're empty for AppStore
                "SUFeedURL": "$(SPARKLE_FEED_URL)",
                "SUPublicEDKey": "$(SPARKLE_PUBLIC_KEY)",
                "SUEnableAutomaticChecks": "$(SPARKLE_AUTO_CHECK)",
                "SUAutomaticallyUpdate": "$(SPARKLE_AUTO_UPDATE)",
                "SUEnableInstallerLauncherService": "$(SPARKLE_INSTALLER_SERVICE)",
            ]),
            sources: ["Sources/MacApp/**"],
            resources: [
                .folderReference(path: "Sources/MacApp/Resources/Fonts"),
                "Sources/MacApp/Resources/menu-bar.svg",
                "Sources/MacApp/Resources/Localizable.xcstrings",
                "Sources/MacApp/Assets.xcassets",
                "Sources/MacApp/PrivacyInfo.xcprivacy",
            ],
            scripts: [
                .post(
                    script: """
                    # Strip Sparkle frameworks from non-SparkleRelease builds
                    # The binary uses weak linking so it runs without them
                    if [ "$CONFIGURATION" != "SparkleRelease" ]; then
                        rm -rf "$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH/Sparkle.framework"
                        rm -rf "$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH/SparkleUpdater.framework"
                    fi
                    """,
                    name: "Strip Sparkle from non-SparkleRelease builds",
                    basedOnDependencyAnalysis: false
                ),
            ],
            dependencies: [
                .target(name: "ClipKittyRust"),
                .target(name: "ClipKittyShared"),
                .target(name: "ClipKittyAppleServices"),
                .target(name: "ClipKittyMacPlatform"),
                .sdk(name: "SystemConfiguration", type: .framework),
                .external(name: "STTextKitPlus"),
                .external(name: "SparkleUpdater"),
            ],
            settings: .settings(
                base: [
                    "OTHER_LDFLAGS": .array(["$(inherited)", "-lpurr"]),
                    "LIBRARY_SEARCH_PATHS": .array(["$(inherited)", "$(PROJECT_DIR)/Sources/ClipKittyRust"]),
                    "SWIFT_EMIT_LOC_STRINGS": "YES",
                    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
                    "DEVELOPMENT_TEAM": "ANBBV7LQ2P",
                ],
                configurations: [
                    .debug(name: "Debug", settings: [
                        "CODE_SIGN_STYLE": "Automatic",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                        "CODE_SIGN_ENTITLEMENTS": "Sources/MacApp/ClipKitty.debug.entitlements",
                        "CK_BUILD_CHANNEL": "Debug",
                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "ENABLE_SYNC",
                        // Weak-link Sparkle frameworks so app runs without them
                        "OTHER_LDFLAGS": .array(["$(inherited)", "-weak_framework", "SparkleUpdater", "-weak_framework", "Sparkle"]),
                    ]),
                    .release(name: "Release", settings: [
                        "CODE_SIGN_STYLE": "Automatic",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                        "CODE_SIGN_ENTITLEMENTS": "Sources/MacApp/ClipKitty.oss.entitlements",
                        "CK_BUILD_CHANNEL": "Release",
                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "ENABLE_SYNC",
                        // Weak-link Sparkle frameworks so app runs without them
                        "OTHER_LDFLAGS": .array(["$(inherited)", "-weak_framework", "SparkleUpdater", "-weak_framework", "Sparkle"]),
                    ]),
                    .release(name: .configuration("SparkleRelease"), settings: [
                        "CODE_SIGN_STYLE": "Automatic",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                        "CODE_SIGN_ENTITLEMENTS": "Sources/MacApp/ClipKitty.sparkle.entitlements",
                        "CK_BUILD_CHANNEL": "Sparkle",
                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "SPARKLE_RELEASE ENABLE_SYNC",
                        // Sparkle configuration - only set for SparkleRelease
                        "SPARKLE_FEED_URL": "https://jul-sh.github.io/clipkitty/appcast.xml",
                        "SPARKLE_PUBLIC_KEY": "9VqfSPPY2Gr8QTYDLa99yJXAFWnHw5aybSbKaYDyCq0=",
                        "SPARKLE_AUTO_CHECK": "YES",
                        "SPARKLE_AUTO_UPDATE": "YES",
                        "SPARKLE_INSTALLER_SERVICE": "YES",
                    ]),
                    .release(name: .configuration("AppStore"), settings: [
                        "CODE_SIGN_STYLE": "Automatic",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                        "CODE_SIGN_ENTITLEMENTS": "Sources/MacApp/ClipKitty.appstore.entitlements",
                        "CK_BUILD_CHANNEL": "AppStore",
                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "APP_STORE ENABLE_SYNC",
                        // Weak-link Sparkle frameworks so app runs without them
                        "OTHER_LDFLAGS": .array(["$(inherited)", "-weak_framework", "SparkleUpdater", "-weak_framework", "Sparkle"]),
                    ]),
                ]
            )
        ),

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
            ],
            settings: .settings(
                base: [
                    "OTHER_LDFLAGS": .array(["$(inherited)", "-lpurr"]),
                    "LIBRARY_SEARCH_PATHS": .array(["$(inherited)", "$(PROJECT_DIR)/Sources/ClipKittyRust"]),
                ]
            )
        ),

        // MARK: ClipKittyUITests — UI tests

        // Debug runs should sign locally so `make uitest` can execute without
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
                configurations: [
                    .debug(name: "Debug", settings: [
                        "CODE_SIGN_STYLE": "Manual",
                        "CODE_SIGN_IDENTITY": "Developer ID Application",
                        "DEVELOPMENT_TEAM": "ANBBV7LQ2P",
                    ]),
                    .release(name: "Release", settings: [
                        "CODE_SIGN_STYLE": "Manual",
                        "CODE_SIGN_IDENTITY": "Developer ID Application",
                        "DEVELOPMENT_TEAM": "ANBBV7LQ2P",
                    ]),
                    .release(name: .configuration("SparkleRelease"), settings: [
                        "CODE_SIGN_STYLE": "Manual",
                        "CODE_SIGN_IDENTITY": "Developer ID Application",
                        "DEVELOPMENT_TEAM": "ANBBV7LQ2P",
                    ]),
                    .release(name: .configuration("AppStore"), settings: [
                        "CODE_SIGN_STYLE": "Manual",
                        "CODE_SIGN_IDENTITY": "Developer ID Application",
                        "DEVELOPMENT_TEAM": "ANBBV7LQ2P",
                    ]),
                ]
            ),
            environmentVariables: [
                "CLIPKITTY_APP_PATH": "$(BUILT_PRODUCTS_DIR)/ClipKitty.app",
            ]
        ),

        // MARK: ClipKittyiOS — iPhone app

        .target(
            name: "ClipKittyiOS",
            destinations: [.iPhone],
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
                configurations: [
                    .debug(name: "Debug", settings: [
                        "CODE_SIGN_STYLE": "Automatic",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                        "CODE_SIGN_ENTITLEMENTS": "Sources/iOSApp/ClipKittyiOS.entitlements",
                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "ENABLE_SYNC",
                    ]),
                    .release(name: "Release", settings: [
                        "CODE_SIGN_STYLE": "Automatic",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                        "CODE_SIGN_ENTITLEMENTS": "Sources/iOSApp/ClipKittyiOS.entitlements",
                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "ENABLE_SYNC",
                    ]),
                    .release(name: .configuration("SparkleRelease"), settings: [:]),
                    .release(name: .configuration("AppStore"), settings: [
                        "CODE_SIGN_STYLE": "Manual",
                        "CODE_SIGN_IDENTITY": "Apple Distribution",
                        "CODE_SIGN_ENTITLEMENTS": "Sources/iOSApp/ClipKittyiOS.appstore.entitlements",
                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "APP_STORE ENABLE_SYNC",
                        "PROVISIONING_PROFILE_SPECIFIER": "ClipKitty iOS AppStore",
                    ]),
                ]
            )
        ),

        // MARK: ClipKittyShare — iOS Share Extension

        .target(
            name: "ClipKittyShare",
            destinations: [.iPhone],
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
                configurations: [
                    .debug(name: "Debug", settings: [
                        "CODE_SIGN_STYLE": "Automatic",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                        "CODE_SIGN_ENTITLEMENTS": "Sources/ShareExtension/ClipKittyShare.entitlements",
                    ]),
                    .release(name: "Release", settings: [
                        "CODE_SIGN_STYLE": "Automatic",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                        "CODE_SIGN_ENTITLEMENTS": "Sources/ShareExtension/ClipKittyShare.entitlements",
                    ]),
                    .release(name: .configuration("SparkleRelease"), settings: [:]),
                    .release(name: .configuration("AppStore"), settings: [
                        "CODE_SIGN_STYLE": "Manual",
                        "CODE_SIGN_IDENTITY": "Apple Distribution",
                        "CODE_SIGN_ENTITLEMENTS": "Sources/ShareExtension/ClipKittyShare.entitlements",
                        "PROVISIONING_PROFILE_SPECIFIER": "ClipKitty Share AppStore",
                    ]),
                ]
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
            ],
            settings: .settings(
                base: [
                    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "ENABLE_SYNC",
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
                preActions: [
                    .executionAction(
                        title: "Build Rust Core",
                        scriptText: """
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
                        if [ -x "Scripts/run-in-nix.sh" ]; then
                            Scripts/run-in-nix.sh -c "cd purr && MACOSX_DEPLOYMENT_TARGET=14.0 cargo run --release --bin generate-bindings"
                            mkdir -p .make && echo "$CURRENT_HASH" > "$MARKER"
                        fi
                        """,
                        target: .target("ClipKitty")
                    ),
                ]
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
        // App Store scheme
        .scheme(
            name: "ClipKitty-AppStore",
            shared: true,
            buildAction: .buildAction(targets: [.target("ClipKitty")]),
            runAction: .runAction(
                configuration: .configuration("AppStore"),
                executable: .target("ClipKitty")
            ),
            archiveAction: .archiveAction(configuration: .configuration("AppStore"))
        ),
        // UI tests scheme
        .scheme(
            name: "ClipKittyUITests",
            shared: true,
            buildAction: .buildAction(
                targets: [
                    .target("ClipKittyUITests"),
                    .target("ClipKitty"),
                ],
                preActions: [
                    .executionAction(
                        title: "Build Rust Core",
                        scriptText: """
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
                        if [ -x "Scripts/run-in-nix.sh" ]; then
                            Scripts/run-in-nix.sh -c "cd purr && MACOSX_DEPLOYMENT_TARGET=14.0 cargo run --release --bin generate-bindings"
                            mkdir -p .make && echo "$CURRENT_HASH" > "$MARKER"
                        fi
                        """,
                        target: .target("ClipKitty")
                    ),
                ]
            ),
            testAction: .testPlans(
                [
                    .relativeToRoot("ClipKittyUITests.xctestplan"),
                    .relativeToRoot("ClipKittyVideoRecording.xctestplan"),
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
    ]
)
