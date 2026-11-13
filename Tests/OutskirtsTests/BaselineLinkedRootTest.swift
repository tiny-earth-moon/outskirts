import Configuration
import Foundation
import Logger
@testable import PeripheryKit
import Shared
@testable import SourceGraph
import SystemPackage
import XCTest

/// Relativization against the project root compares resolved paths, so that a root reached through a link (or `/tmp`
/// against `/private/tmp`) gives the same baseline as the real directory.
final class BaselineLinkedRootTest: XCTestCase {
    private var parent = ""

    override func setUpWithError() throws {
        parent = NSTemporaryDirectory() + "outskirts-linked-root-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: parent + "/real/Sources/Lib", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: parent + "/real/Sources/Lib/A.swift", contents: Data())
        try FileManager.default.createSymbolicLink(atPath: parent + "/link", withDestinationPath: parent + "/real")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: parent)
    }

    private func entryFile(file: String, root: String) throws -> String? {
        let configuration = Configuration()
        configuration.projectRoot = FilePath(root)
        let graph = SourceGraph(configuration: configuration, logger: Logger(quiet: true, verbose: false, colorMode: .never))
        let sourceFile = SourceFile(path: FilePath(file), modules: ["Lib"])
        graph.markEmptyExtension(extendedTypeName: "Used", location: Location(file: sourceFile, line: 1, column: 1))
        let results = graph.emptyExtensions.map { ScanResult(declaration: $0, annotation: .emptyExtension) }
        let baseline = Baseline.written(from: results, union: nil, projectRoot: FilePath(root))
        XCTAssertEqual(baseline.entries.first?.id, "empty-extension-Used-Sources/Lib/A.swift")
        return baseline.entries.first?.file
    }

    func testBaseline_rootThroughLink_fileThroughRealPath_isRelative() throws {
        XCTAssertEqual(try entryFile(file: parent + "/real/Sources/Lib/A.swift", root: parent + "/link"), "Sources/Lib/A.swift")
    }

    func testBaseline_realRoot_fileThroughLink_isRelative() throws {
        XCTAssertEqual(try entryFile(file: parent + "/link/Sources/Lib/A.swift", root: parent + "/real"), "Sources/Lib/A.swift")
    }

    func testBaseline_fileOutsideRoot_staysAbsolute() throws {
        let outside = NSTemporaryDirectory() + "elsewhere/B.swift"
        XCTAssertNil(RealPath.relativePath(of: FilePath(outside), within: FilePath(parent + "/real")))
    }
}
