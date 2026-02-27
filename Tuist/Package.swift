// swift-tools-version: 6.2
import PackageDescription

#if TUIST
import ProjectDescription

let packageSettings = PackageSettings(
    productTypes: ["Sparkle": .framework]
)
#endif

let package = Package(
    name: "ClipKittyDependencies",
    dependencies: [
        // GRDB used for FTS integration tests
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.0"),
    ]
)
