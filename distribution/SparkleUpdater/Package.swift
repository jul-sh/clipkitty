// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SparkleUpdater",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SparkleUpdater", targets: ["SparkleUpdater"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.9.4"),
    ],
    targets: [
        .target(
            name: "SparkleUpdater",
            dependencies: ["Sparkle"]
        ),
    ]
)
