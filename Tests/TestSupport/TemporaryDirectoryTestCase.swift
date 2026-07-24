import Foundation
import XCTest

class TemporaryDirectoryTestCase: XCTestCase {
    private(set) var temporaryDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkitty-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectory = directory
    }

    override func tearDown() async throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try await super.tearDown()
    }

    func databasePath(_ filename: String = "clipboard.sqlite") -> String {
        temporaryDirectory.appendingPathComponent(filename).path
    }
}
