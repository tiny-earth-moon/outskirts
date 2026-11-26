@testable import Facade
import XCTest

final class FacadeClientTests: XCTestCase {
    func testReexportedDeclaration() {
        XCTAssertEqual(exportedThroughFacade(), "exported")
    }

    func testFacadeDeclaration() {
        XCTAssertEqual(facadeTestableHelper(), "facade")
    }
}
