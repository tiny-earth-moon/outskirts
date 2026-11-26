import LayerC
import XCTest

final class LayerCClientTests: XCTestCase {
    func testFarewell() {
        XCTAssertEqual(farewellFromC(), "bye")
    }

    func testRetentionHolderB() {
        XCTAssertEqual(useRetentionHolderB(), 4)
    }
}
