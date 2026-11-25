@testable import Model
import Helpers
import XCTest

final class ImportedValueTests: XCTestCase {
    func testPublicFactory() {
        let value = ImportedValue.makeImportedValue()
        XCTAssertEqual(String(reflecting: value), "ImportedValue")
    }
}
