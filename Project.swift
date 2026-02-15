import ProjectDescription

// MARK: - Build Configurations
// Debug:    non-sandboxed, for development
// Release:  non-sandboxed, for DMG distribution
// AppStore: sandboxed (-DSANDBOXED), for App Store

let configurations: [Configuration] = [
    .debug(name: "Debug", settings: [:]),
    .release(name: "Release", settings: [:]),
    .release(name: .configuration("AppStore"), settings: [
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "SANDBOXED",
    ]),
]

// MARK: - Project

let project = Project(
    name: "ClipKitty",
    settings: .settings(
        base: [
            "MARKETING_VERSION": "1.6.0",
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
            deploymentTargets: .macOS("15.0"),
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
            deploymentTargets: .macOS("15.0"),
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
            deploymentTargets: .macOS("15.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "ClipKitty",
                "CFBundleIconName": "AppIcon",
                "CFBundleIconFile": "AppIcon",
                "LSMinimumSystemVersion": "15.0",
                "NSHumanReadableCopyright": "Copyright © 2025 ClipKitty. All rights reserved.",
            ]),
            sources: ["Sources/App/**"],
            resources: [
                .folderReference(path: "Sources/App/Resources/Fonts"),
                "Sources/App/Resources/menu-bar.svg",
                "Sources/App/Assets.xcassets",
                "Sources/App/PrivacyInfo.xcprivacy",
            ],
            dependencies: [
                .target(name: "ClipKittyRust"),
                .sdk(name: "SystemConfiguration", type: .framework),
            ],
            settings: .settings(
                base: [
                    "OTHER_LDFLAGS": .array(["$(inherited)", "-lpurr"]),
                    "LIBRARY_SEARCH_PATHS": .array(["$(inherited)", "$(PROJECT_DIR)/Sources/ClipKittyRust"]),
                ],
                configurations: [
                    .debug(name: "Debug", settings: [
                        "CODE_SIGN_ENTITLEMENTS": "Sources/App/ClipKitty.entitlements",
                    ]),
                    .release(name: "Release", settings: [
                        "CODE_SIGN_ENTITLEMENTS": "Sources/App/ClipKitty.entitlements",
                    ]),
                    .release(name: .configuration("AppStore"), settings: [
                        "CODE_SIGN_ENTITLEMENTS": "Sources/App/ClipKitty-Sandboxed.entitlements",
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
            deploymentTargets: .macOS("15.0"),
            sources: .sourceFilesList(globs: [
                .glob("Tests/**", excluding: ["Tests/UITests/**"]),
            ]),
            dependencies: [
                .target(name: "ClipKittyRust"),
                .external(name: "GRDB"),
            ]
        ),

        // MARK: ClipKittyUITests — UI tests
        .target(
            name: "ClipKittyUITests",
            destinations: .macOS,
            product: .uiTests,
            bundleId: "com.clipkitty.UITests",
            deploymentTargets: .macOS("15.0"),
            sources: ["Tests/UITests/**"],
            entitlements: .file(path: "Tests/UITests/ClipKittyUITests.entitlements"),
            dependencies: [
                .target(name: "ClipKitty"),
            ],
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
                        if [ -x "$PROJECT_DIR/Scripts/run-in-nix.sh" ]; then
                            "$PROJECT_DIR/Scripts/run-in-nix.sh" -c "cd $PROJECT_DIR/purr && cargo run --release --bin generate-bindings"
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
        // Release scheme for DMG distribution
        .scheme(
            name: "ClipKitty-Release",
            shared: true,
            buildAction: .buildAction(targets: [.target("ClipKitty")]),
            runAction: .runAction(
                configuration: "Release",
                executable: .target("ClipKitty")
            ),
            archiveAction: .archiveAction(configuration: "Release")
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
            buildAction: .buildAction(targets: [
                .target("ClipKittyUITests"),
                .target("ClipKitty"),
            ]),
            testAction: .targets(
                [.testableTarget(target: .target("ClipKittyUITests"))],
                configuration: "Debug"
            )
        ),
    ],
    additionalFiles: [
        "Sources/App/ClipKitty.entitlements",
        "Sources/App/ClipKitty-Sandboxed.entitlements",
    ]
)
