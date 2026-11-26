@testable import ChainHelpers
import XCTest

final class ChainValueTests: XCTestCase {
    func testMemberThroughTestableImport() {
        XCTAssertEqual(makeChainValue().chainLabel, "ChainValue")
    }
}
