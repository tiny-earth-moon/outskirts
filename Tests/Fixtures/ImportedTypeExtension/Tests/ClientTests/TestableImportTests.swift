@testable import Helpers
@testable import Model
import XCTest

final class TestableImportTests: XCTestCase {
    func testFactoryThroughTestableImport() {
        _ = ImportedValue.makeTestableValue()
    }
}
