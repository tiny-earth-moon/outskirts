import Foundation
@testable import Frontend
import Shared
import XCTest

final class UpdateCheckResponseTest: XCTestCase {
    func testPlainVersionTagIsAccepted() throws {
        let data = Data(#"{"tag_name": "3.22.0", "name": "3.22.0"}"#.utf8)

        XCTAssertEqual(try UpdateChecker.latestVersion(fromResponse: data).get(), "3.22.0")
    }

    func testTagThatIsNotAPlainVersionIsRejected() {
        for tag in ["v3.22.0", "3.22.0-beta", "3..0", "", "3.22.0\u{1B}[2J", "\u{0661}.2", String(repeating: "9", count: 50)] {
            let data = try! JSONSerialization.data(withJSONObject: ["tag_name": tag])

            XCTAssertThrowsError(try UpdateChecker.latestVersion(fromResponse: data).get(), tag)
        }
    }

    func testOversizedResponseIsRejected() {
        let padding = String(repeating: " ", count: UpdateChecker.maximumResponseSize)
        let data = Data(#"{"tag_name": "3.22.0"}\#(padding)"#.utf8)

        XCTAssertThrowsError(try UpdateChecker.latestVersion(fromResponse: data).get()) { error in
            XCTAssertTrue("\(error)".contains("larger than the 65536 bytes limit"), "\(error)")
        }
    }

    func testMissingOrInvalidBodyIsRejected() {
        for data in [nil, Data("not json".utf8), Data(#"["3.22.0"]"#.utf8), Data(#"{"tag_name": 3}"#.utf8)] {
            XCTAssertThrowsError(try UpdateChecker.latestVersion(fromResponse: data).get())
        }
    }
}
