// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipKittyExternalDependencies",
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/STTextKitPlus.git", exact: "0.3.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.9.0"),
    ]
)
