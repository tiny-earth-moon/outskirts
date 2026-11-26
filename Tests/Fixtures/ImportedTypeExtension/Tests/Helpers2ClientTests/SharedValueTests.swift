import Helpers2
@testable import Model
import XCTest

final class SharedValueTests: XCTestCase {
    func testFactoryOfSecondExtension() {
        _ = SharedValue.makeSharedFromHelpers2()
    }

    func testRetroactiveConformance() {
        XCTAssertEqual(String(describing: RetroValue()), "RetroValue")
    }
}
