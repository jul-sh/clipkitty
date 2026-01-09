// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ClipKitty",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .executableTarget(
            name: "ClipKitty",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources",
            resources: [
                .copy("Resources")
            ]
        ),
        .executableTarget(
            name: "PopulateTestData",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Scripts/PopulateTestData"
        )
    ]
)
