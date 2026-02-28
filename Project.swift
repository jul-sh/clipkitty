import ProjectDescription

// MARK: - Build Configurations
// Debug:    for development
// Release:  for DMG distribution
// AppStore: for App Store (differs only in signing)

let configurations: [Configuration] = [
    .debug(name: "Debug", settings: [:]),
    .release(name: "Release", settings: [:]),
    .release(name: .configuration("AppStore"), settings: [:]),
]

// MARK: - Project

let project = Project(
    name: "ClipKitty",
    settings: .settings(
        base: [
            "MARKETING_VERSION": "1.8.11",
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
            destinations: .macOS,
            product: .staticLibrary,
            bundleId: "com.eviljuliette.clipkitty.rustffi",
            deploymentTargets: .macOS("14.0"),
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
            destinations: .macOS,
            product: .staticLibrary,
            bundleId: "com.eviljuliette.clipkitty.rust",
            deploymentTargets: .macOS("14.0"),
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
                "ITSAppUsesNonExemptEncryption": false,
                "LSApplicationCategoryType": "public.app-category.utilities",
                "LSMinimumSystemVersion": "14.0",
                "NSHumanReadableCopyright": "Copyright © 2025 ClipKitty. All rights reserved.",
                "SUFeedURL": "https://jul-sh.github.io/clipkitty/appcast.xml",
                "SUPublicEDKey": "9VqfSPPY2Gr8QTYDLa99yJXAFWnHw5aybSbKaYDyCq0=",
                "SUEnableAutomaticChecks": true,
                "SUAutomaticallyUpdate": true,
                "SUEnableInstallerLauncherService": true,
            ]),
            sources: ["Sources/App/**"],
            resources: [
                .folderReference(path: "Sources/App/Resources/Fonts"),
                "Sources/App/Resources/menu-bar.svg",
                "Sources/App/Resources/Localizable.xcstrings",
                "Sources/App/Assets.xcassets",
                "Sources/App/PrivacyInfo.xcprivacy",
            ],
            scripts: [
                .post(
                    script: """
                    if [ "$CONFIGURATION" = "AppStore" ]; then
                        rm -rf "$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH/Sparkle.framework"
                        PLIST="$BUILT_PRODUCTS_DIR/$INFOPLIST_PATH"
                        /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$PLIST" 2>/dev/null || true
                        /usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$PLIST" 2>/dev/null || true
                        /usr/libexec/PlistBuddy -c "Delete :SUEnableAutomaticChecks" "$PLIST" 2>/dev/null || true
                        /usr/libexec/PlistBuddy -c "Delete :SUAutomaticallyUpdate" "$PLIST" 2>/dev/null || true
                        /usr/libexec/PlistBuddy -c "Delete :SUEnableInstallerLauncherService" "$PLIST" 2>/dev/null || true
                    fi
                    """,
                    name: "Strip Sparkle from AppStore builds",
                    basedOnDependencyAnalysis: false
                ),
            ],
            dependencies: [
                .target(name: "ClipKittyRust"),
                .sdk(name: "SystemConfiguration", type: .framework),
                .external(name: "Sparkle"),
            ],
            settings: .settings(
                base: [
                    "OTHER_LDFLAGS": .array(["$(inherited)", "-lpurr"]),
                    "LIBRARY_SEARCH_PATHS": .array(["$(inherited)", "$(PROJECT_DIR)/Sources/ClipKittyRust"]),
                    "SWIFT_EMIT_LOC_STRINGS": "YES",
                    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
                ],
                configurations: [
                    .debug(name: "Debug", settings: [
                        "CODE_SIGN_ENTITLEMENTS": "Sources/App/ClipKitty.oss.entitlements",
                    ]),
                    .release(name: "Release", settings: [
                        "CODE_SIGN_ENTITLEMENTS": "Sources/App/ClipKitty.oss.entitlements",
                        "CURRENT_PROJECT_VERSION": "$(MARKETING_VERSION)",
                    ]),
                    .release(name: .configuration("AppStore"), settings: [
                        "CODE_SIGN_ENTITLEMENTS": "Sources/App/ClipKitty.appstore.entitlements",
                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "APP_STORE",
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
                .glob("Tests/**", excluding: ["Tests/UITests/**"]),
            ]),
            dependencies: [
                .target(name: "ClipKittyRust"),
            ],
            settings: .settings(
                base: [
                    "OTHER_LDFLAGS": .array(["$(inherited)", "-lpurr"]),
                    "LIBRARY_SEARCH_PATHS": .array(["$(inherited)", "$(PROJECT_DIR)/Sources/ClipKittyRust"]),
                ]
            )
        ),

        // MARK: ClipKittyUITests — UI tests
        // Sign with Developer ID to preserve TCC permissions across builds.
        // Run ./distribution/setup-dev-signing.sh first to import the certificate.
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
                base: [
                    "CODE_SIGN_STYLE": "Manual",
                    "CODE_SIGN_IDENTITY": "Developer ID Application",
                    "DEVELOPMENT_TEAM": "ANBBV7LQ2P",
                ]
            ),
            environmentVariables: [
                "CLIPKITTY_APP_PATH": "$(BUILT_PRODUCTS_DIR)/ClipKitty.app",
            ]
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
                            Scripts/run-in-nix.sh -c "cd purr && cargo run --release --bin generate-bindings"
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
                    .testableTarget(target: .target("ClipKittyUITests")),
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
                            Scripts/run-in-nix.sh -c "cd purr && cargo run --release --bin generate-bindings"
                            mkdir -p .make && echo "$CURRENT_HASH" > "$MARKER"
                        fi
                        """,
                        target: .target("ClipKitty")
                    ),
                ]
            ),
            testAction: .targets(
                [.testableTarget(target: .target("ClipKittyUITests"))],
                configuration: "Debug"
            )
        ),
    ],
    additionalFiles: [
        "Sources/App/ClipKitty.oss.entitlements",
    ]
)
