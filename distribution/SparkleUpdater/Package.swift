// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SparkleUpdater",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SparkleUpdater", targets: ["SparkleUpdater"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.0"),
    ],
    targets: [
        .target(
            name: "SparkleUpdater",
            dependencies: ["Sparkle"]
        ),
    ]
)
