// swift-tools-version: 6.2
import PackageDescription

#if TUIST
import ProjectDescription

let packageSettings = PackageSettings(
    productTypes: [:]
)
#endif

let package = Package(
    name: "ClipKittyDependencies",
    dependencies: [
        // GRDB used for FTS integration tests
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ]
)
