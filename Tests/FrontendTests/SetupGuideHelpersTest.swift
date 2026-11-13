import Logger
import Shared
import XCTest

final class SetupGuideHelpersTest: XCTestCase {
    func testPrompts_throwAtEndOfInputWithoutLooping() {
        let helpers = SetupGuideHelpers(logger: Logger(quiet: true, verbose: false, colorMode: .never))
        let prompts: [(String, () throws -> Void)] = [
            ("single", { _ = try helpers.select(single: ["a", "b"]) }),
            ("multiple", { _ = try helpers.select(multiple: ["a", "b"]) }),
            ("boolean", { _ = try helpers.selectBoolean() }),
        ]

        for (name, prompt) in prompts {
            var reads = 0
            // Bounded: after a few end-of-input reads, answer validly so a looping prompt terminates.
            helpers.readInput = {
                reads += 1
                return reads > 3 ? "1" : nil
            }
            if name == "boolean" {
                helpers.readInput = {
                    reads += 1
                    return reads > 3 ? "y" : nil
                }
            }

            XCTAssertThrowsError(try prompt(), name) { error in
                guard case let PeripheryError.guidedSetupError(message) = error else {
                    return XCTFail("\(name): unexpected error \(error)")
                }

                XCTAssertTrue(message.contains("end of the input"), name)
            }
            XCTAssertEqual(reads, 1, name)
        }
    }

    func testPrompts_retryInvalidInputThenAccept() throws {
        let helpers = SetupGuideHelpers(logger: Logger(quiet: true, verbose: false, colorMode: .never))
        var lines = ["x", "3", "2"]
        helpers.readInput = { lines.isEmpty ? nil : lines.removeFirst() }
        XCTAssertEqual(try helpers.select(single: ["a", "b"]), "b")

        lines = ["1 x", "", "1 2"]
        XCTAssertEqual(try helpers.select(multiple: ["a", "b"]).selectedValues, ["a", "b"])

        lines = ["maybe", "No"]
        XCTAssertFalse(try helpers.selectBoolean())
    }
}
