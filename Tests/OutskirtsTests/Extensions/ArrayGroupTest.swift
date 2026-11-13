import Extensions
import XCTest

final class ArrayGroupTest: XCTestCase {
    func testGroupKeepsTheOrderOfElementsWithinEachKey() {
        let groups = ["a1", "b1", "a2", "c1", "b2", "a3"].group { $0.prefix(1) }

        XCTAssertEqual(groups, ["a": ["a1", "a2", "a3"], "b": ["b1", "b2"], "c": ["c1"]])
    }

    func testGroupHandlesALargeInputInLinearTime() {
        let elements = Array(0 ..< 200_000)
        let start = Date()

        let groups = elements.group { $0 % 1000 }

        XCTAssertEqual(groups.count, 1000)
        XCTAssertEqual(groups[7]?.count, 200)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}
