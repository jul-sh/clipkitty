// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ClipKitty",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "ClipKittyCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/Core"
        ),
        .executableTarget(
            name: "ClipKitty",
            dependencies: [
                "ClipKittyCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/App",
            resources: [
                .copy("Resources/Fonts"),
                .copy("Resources/menu-bar.svg")
            ]
        ),
        .executableTarget(
            name: "PopulateTestData",
            dependencies: [
                "ClipKittyCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Scripts/PopulateTestData"
        ),
        .testTarget(
            name: "ClipKittyTests",
            dependencies: [
                "ClipKittyCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Tests"
        )
    ]
)
