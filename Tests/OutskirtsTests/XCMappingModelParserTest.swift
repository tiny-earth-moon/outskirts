import Foundation
@testable import Indexer
import SystemPackage
import TestShared
import XCTest

final class XCMappingModelParserTest: XCTestCase {
    func testThrowsForMissingFile() {
        XCTAssertThrowsError(try XCMappingModelParser(input: .directory(missingPath("xcmappingmodel"))).parse())
    }
}
