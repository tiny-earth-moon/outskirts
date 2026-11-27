import Configuration
import Foundation
import Logger
@testable import PeripheryKit
import SourceGraph
import SystemPackage
import XCTest

final class TestOnlyResultFormatTest: XCTestCase {
    private let logger = Logger(quiet: true, verbose: false, colorMode: .never)
    private let root = FilePath("/Project")

    private func results() -> [ScanResult] {
        let badges = SourceFile(path: root.appending("Sources/App/LegacyBadge.swift"), modules: ["App"])
        let badge = Declaration(
            name: "LegacyBadge",
            kind: .struct,
            usrs: ["s:3App11LegacyBadgeV"],
            location: Location(file: badges, line: 3, column: 8)
        )

        return [ScanResult(declaration: badge, annotation: .testOnly)]
    }

    func testXcodeOutput_saysTheDeclarationIsUsedOnlyByTests() throws {
        let output = try XcodeFormatter(configuration: Configuration(), logger: logger).format(results(), colored: false)

        XCTAssertEqual(output, "/Project/Sources/App/LegacyBadge.swift:3:8: warning: Test-only struct 'LegacyBadge' is used only by tests")
    }

    func testJsonOutput_carriesTheTestOnlyHint() throws {
        let output = try XCTUnwrap(JsonFormatter(configuration: Configuration(), logger: logger).format(results(), colored: false))
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]])

        XCTAssertEqual(objects.map { $0["kind"] as? String }, ["struct"])
        XCTAssertEqual(objects.map { $0["hints"] as? [String] }, [["testOnly"]])
        XCTAssertEqual(objects.map { $0["ids"] as? [String] }, [["s:3App11LegacyBadgeV"]])
    }

    func testSarifOutput_usesTheTestOnlyRule() throws {
        let output = try XCTUnwrap(SarifFormatter(configuration: Configuration(), logger: logger).format(results(), colored: false))
        let sarif = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let run = try XCTUnwrap((sarif["runs"] as? [[String: Any]])?.first)
        let result = try XCTUnwrap((run["results"] as? [[String: Any]])?.first)

        XCTAssertEqual(result["ruleId"] as? String, "testOnly")
        XCTAssertTrue(SarifFormatter.rules.contains { $0.id == "testOnly" && $0.help == "analysis/#test-only-declarations" })
    }

    func testEveryFormat_rendersTheResult() throws {
        for format in OutputFormat.allCases {
            let output = try format.formatter.init(configuration: Configuration(), logger: logger).format(results(), colored: false)
            XCTAssertTrue(output?.contains("LegacyBadge") == true, "\(format)")
        }
    }

    func testAgentOutput_listsItInItsOwnSection() throws {
        let output = try XCTUnwrap(AgentFormatter(configuration: Configuration(), logger: logger).format(results(), colored: false))

        XCTAssertTrue(output.contains("## Review code used only by tests"))
        XCTAssertFalse(output.contains("## Remove unused code"))
        XCTAssertTrue(output.contains("used only by tests, delete it with the tests that use it or use it in the app"))
    }

    func testBaselineId_isDistinctFromTheDeclarationIds() throws {
        let result = try XCTUnwrap(results().first)

        XCTAssertEqual(result.usrs, ["test-only-s:3App11LegacyBadgeV"])

        let baseline = Baseline.written(from: results(), union: nil, projectRoot: root)
        let matcher = BaselineMatcher(try JSONDecoder().decode(Baseline.self, from: baseline.encoded()), projectRoot: root)
        XCTAssertEqual(matcher.match(result), .current)
    }

    func testResultKind_isTheTestOnlyAnnotation() throws {
        XCTAssertEqual(ResultKind.identifier(of: try XCTUnwrap(results().first)), "testOnly.struct")
        XCTAssertTrue(ResultKind.isValid("testOnly"))
        XCTAssertTrue(ResultKind.isValid("testOnly.struct"))
    }
}
