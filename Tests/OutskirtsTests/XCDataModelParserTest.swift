import Foundation
@testable import Indexer
import SystemPackage
import TestShared
import XCTest

final class XCDataModelParserTest: XCTestCase {
    func testThrowsForMissingFile() throws {
        let model = uniqueTemporaryURL("Model", suffix: ".xcdatamodeld")
        try FileManager.default.createDirectory(at: model.appendingPathComponent("Model.xcdatamodel"), withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: model) }

        // A model version without its `contents` file.
        XCTAssertThrowsError(try XCDataModelParser(input: .directory(FilePath(model.path))).parse())
    }
}
