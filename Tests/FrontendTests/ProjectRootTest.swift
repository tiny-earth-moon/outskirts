import Foundation
@testable import Frontend
import Shared
import SystemPackage
import XCTest

/// A relative or linked `--project-root` must give the same root as the real absolute directory.
final class ProjectRootTest: XCTestCase {
    private var originalDirectory = ""
    private var parent = ""
    private var project = ""

    override func setUpWithError() throws {
        originalDirectory = FileManager.default.currentDirectoryPath
        parent = NSTemporaryDirectory() + "outskirts-project-root-\(UUID().uuidString)"
        project = parent + "/p3"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        FileManager.default.changeCurrentDirectoryPath(originalDirectory)
        try FileManager.default.removeItem(atPath: parent)
    }

    private var realProject: String {
        RealPath.resolve(project)
    }

    func testRelativeRoot_isAbsoluteAfterChangingDirectory() throws {
        FileManager.default.changeCurrentDirectoryPath(parent)

        let root = try ScanCommand.changeToProjectRoot(FilePath("p3"))

        XCTAssertTrue(root.isAbsolute)
        XCTAssertEqual(root.string, realProject)
        XCTAssertEqual(FileManager.default.currentDirectoryPath, realProject)
    }

    func testLinkedRoot_resolvesToTheRealDirectory() throws {
        let link = parent + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: project)

        let root = try ScanCommand.changeToProjectRoot(FilePath(link))

        XCTAssertEqual(root.string, realProject)
    }
}
