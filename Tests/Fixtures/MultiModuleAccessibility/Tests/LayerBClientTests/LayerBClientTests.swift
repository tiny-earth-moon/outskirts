import LayerB
import XCTest

final class LayerBClientTests: XCTestCase {
    func testPackageScope() {
        XCTAssertEqual(usePackageScope(), "1245")
    }

    func testSPIEntry() {
        XCTAssertEqual(useSPIEntry(), 3)
    }

    func testGreeting() {
        XCTAssertEqual(greetFromB(), "hello")
    }

    func testRetentionHolderA() {
        XCTAssertEqual(useRetentionHolderA(), 5)
    }
}
