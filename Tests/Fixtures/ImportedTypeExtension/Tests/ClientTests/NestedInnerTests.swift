import Helpers
@testable import Model
import XCTest

final class NestedInnerTests: XCTestCase {
    func testNestedFactory() {
        _ = NestedOuter.NestedInner.makeNestedInner()
    }

    func testImportedWitness() {
        XCTAssertEqual(DescribedValue().describeImported(), "DescribedValue")
    }
}
