import Foundation
import Shared
import XCTest

final class ConcurrentlyTest: XCTestCase {
    private struct Failure: Error, Equatable {
        // outskirts:ignore - only compared, through the synthesized Equatable conformance
        let id: Int
    }

    func testRun_returnsBothResultsInOrder() throws {
        let (first, second) = try Concurrently.run({ "describe" }, { 42 })

        XCTAssertEqual(first, "describe")
        XCTAssertEqual(second, 42)
    }

    func testRun_overlapsTheTwoBlocks() throws {
        let secondStarted = DispatchSemaphore(value: 0)

        let (overlapped, _) = try Concurrently.run(
            { secondStarted.wait(timeout: .now() + 10) == .success },
            { secondStarted.signal() }
        )

        XCTAssertTrue(overlapped, "the first block waits for the second one, which serial execution never starts")
    }

    func testRun_throwsTheErrorOfTheFirstBlockFirst() {
        XCTAssertThrowsError(try Concurrently.run({ throw Failure(id: 1) }, { throw Failure(id: 2) })) {
            XCTAssertEqual($0 as? Failure, Failure(id: 1))
        }
        XCTAssertThrowsError(try Concurrently.run({ 1 }, { throw Failure(id: 2) })) {
            XCTAssertEqual($0 as? Failure, Failure(id: 2))
        }
    }

    func testMap_keepsTheOrderOfTheElements() throws {
        let elements = Array(0 ..< 200)

        XCTAssertEqual(Concurrently.map(elements) { $0 * 2 }, elements.map { $0 * 2 })
    }

    func testMap_throwsTheErrorOfTheFirstFailingElement() {
        XCTAssertThrowsError(try Concurrently.map(Array(0 ..< 50)) {
            if $0 % 10 == 3 {
                throw Failure(id: $0)
            }
        }) {
            XCTAssertEqual($0 as? Failure, Failure(id: 3))
        }
    }
}
