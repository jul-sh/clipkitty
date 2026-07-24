import Foundation
import ProjectDescription

let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let usesPreResolvedXcodePackages = FileManager.default.fileExists(
    atPath: repositoryRoot.appending(path: ".package.resolved").path
)

let config = Config(
    compatibleXcodeVersions: .all,
    swiftVersion: "6.2",
    generationOptions: .options(
        disablePackageVersionLocking: usesPreResolvedXcodePackages
    )
)
