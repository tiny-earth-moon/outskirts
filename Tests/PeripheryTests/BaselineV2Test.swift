import Configuration
import Foundation
import Logger
@testable import PeripheryKit
@testable import SourceGraph
import SystemPackage
import XCTest

/// The baseline of format `v2`, `{"version": 2, "ids": [...]}`: it holds output v2 ids, which include the rule, so a
/// declaration baselined for one rule is still reported for another. Baselines of format `v1` keep matching by USR.
final class BaselineV2Test: XCTestCase {
    private let logger = Logger(quiet: true, verbose: false, colorMode: .never)
    private let root = "/work/project"

    // MARK: - Matching

    func testBaselinedRedundantPublicResult_isReportedAgainOnceTheDeclarationBecomesUnused() throws {
        let baseline = try roundTrip(written(from: [redundantPublic()], format: .v2))

        XCTAssertEqual(try filter([redundantPublic()], with: baseline), [])
        XCTAssertEqual(try filter([unused()], with: baseline), ["unused helper()"])
    }

    func testVersionOneBaseline_stillHidesTheDeclarationForEveryRule() throws {
        let baseline = try roundTrip(written(from: [redundantPublic()], format: .v1))

        XCTAssertEqual(baseline.format, .v1)
        XCTAssertEqual(try filter([redundantPublic()], with: baseline), [])
        XCTAssertEqual(try filter([unused()], with: baseline), [])
    }

    func testVersionTwoBaseline_matchesWhenTheDeclarationMovesOrTheCheckoutChanges() throws {
        let baseline = written(from: [redundantPublic()], format: .v2)

        XCTAssertEqual(try filter([redundantPublic(line: 40)], with: baseline), [])
        XCTAssertEqual(try filter([redundantPublic(root: "/elsewhere")], with: baseline, root: "/elsewhere"), [])
    }

    func testVersionTwoBaseline_ignoresTheUsrsOfAVersionOneEntry() throws {
        let baseline = Baseline.outputV2(ids: ["s:3Lib6helperyyF"])

        XCTAssertEqual(try filter([unused()], with: baseline), ["unused helper()"])
    }

    func testVersionTwoBaseline_countsItsStaleIds() throws {
        let filter = OutputDeclarationFilter(configuration: configuration(), logger: logger)
        let stale = OutputV2Id.id(rule: .unused, identity: ["s:3Lib4goneyyF"])

        _ = try filter.filter([redundantPublic()], with: .outputV2(ids: [OutputV2Id.id(of: redundantPublic()), stale]))

        XCTAssertEqual(filter.staleBaselineEntries, [stale])
    }

    // MARK: - File

    func testVersionTwoFile_holdsTheVersionAndTheSortedIds() throws {
        let text = try XCTUnwrap(String(bytes: written(from: [unused(), redundantPublic()], format: .v2).encoded(), encoding: .utf8))
        let ids = [OutputV2Id.id(of: unused()), OutputV2Id.id(of: redundantPublic())].sorted()

        XCTAssertEqual(text, """
        {
          "ids" : [
            "\(ids[0])",
            "\(ids[1])"
          ],
          "version" : 2
        }

        """)
    }

    func testVersionTwoFile_roundTripsByteStable() throws {
        let written = written(from: [unused(), redundantPublic()], format: .v2)
        let data = try written.encoded()
        let decoded = try JSONDecoder().decode(Baseline.self, from: data)

        XCTAssertEqual(decoded, written)
        XCTAssertEqual(decoded.format, .v2)
        XCTAssertEqual(try decoded.encoded(), data)
    }

    func testFileOfAnotherVersion_isRejected() {
        XCTAssertThrowsError(try JSONDecoder().decode(Baseline.self, from: Data(#"{"version": 3, "ids": []}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(Baseline.self, from: Data(#"{"version": 2}"#.utf8)))
    }

    // MARK: - Writing

    func testWriteBaseline_keepsTheIdsOfAVersionTwoBaseline() {
        let previous = Baseline.outputV2(ids: ["p2_kept"])

        XCTAssertEqual(
            Baseline.written(from: [unused()], union: previous, format: .v2, projectRoot: FilePath(root)).usrs,
            ["p2_kept", OutputV2Id.id(of: unused())]
        )
    }

    func testWriteBaselineInVersionTwo_convertsAVersionOneBaselineThroughTheResultsItMatched() throws {
        let previous = Baseline.v1(usrs: ["s:3Lib6helperyyF", "s:3Lib4goneyyF"])
        let filter = OutputDeclarationFilter(configuration: configuration(), logger: logger)
        let shown = try filter.filter([redundantPublic(), other()], with: previous)

        let upgraded = Baseline.written(from: shown, union: previous, matchedResults: filter.baselineMatchedResults, format: .v2, projectRoot: FilePath(root))

        XCTAssertEqual(upgraded, .outputV2(ids: [OutputV2Id.id(of: redundantPublic()), OutputV2Id.id(of: other())].sorted()))
    }

    func testWriteBaselineInVersionOne_convertsAVersionTwoBaselineThroughTheResultsItMatched() {
        let previous = Baseline.outputV2(ids: [OutputV2Id.id(of: redundantPublic())])

        let downgraded = Baseline.written(from: [other()], union: previous, matchedResults: [redundantPublic()], format: .v1, projectRoot: FilePath(root))

        XCTAssertEqual(downgraded.usrs, ["s:3Lib6helperyyF", "s:3Lib5otheryyF"])
        XCTAssertEqual(downgraded.format, .v1)
    }

    func testPrunedVersionTwoBaseline_staysInVersionTwo() throws {
        let filter = OutputDeclarationFilter(configuration: configuration(), logger: logger)
        let baseline = Baseline.outputV2(ids: [OutputV2Id.id(of: redundantPublic()), "p2_stale"])

        _ = try filter.filter([redundantPublic()], with: baseline)

        XCTAssertEqual(
            Baseline.pruned(keeping: filter.baselineMatchedResults, format: baseline.format, projectRoot: FilePath(root)),
            .outputV2(ids: [OutputV2Id.id(of: redundantPublic())])
        )
    }

    // MARK: - Fixture

    private func configuration(root: String? = nil) -> Configuration {
        let configuration = Configuration()
        configuration.projectRoot = FilePath(root ?? self.root)
        return configuration
    }

    private func helper(root: String? = nil, line: Int = 5) -> Declaration {
        let file = SourceFile(path: FilePath((root ?? self.root) + "/Sources/Lib/Helper.swift"), modules: ["Lib"])
        let declaration = Declaration(name: "helper()", kind: .functionFree, usrs: ["s:3Lib6helperyyF"], location: Location(file: file, line: line, column: 13))
        declaration.accessibility = DeclarationAccessibility(value: .public, isExplicit: true)
        return declaration
    }

    private func redundantPublic(root: String? = nil, line: Int = 5) -> ScanResult {
        ScanResult(declaration: helper(root: root, line: line), annotation: .redundantPublicAccessibility(modules: ["Lib"]))
    }

    private func unused() -> ScanResult {
        ScanResult(declaration: helper(), annotation: .unused)
    }

    private func other() -> ScanResult {
        let file = SourceFile(path: FilePath(root + "/Sources/Lib/Other.swift"), modules: ["Lib"])
        return ScanResult(declaration: Declaration(name: "other()", kind: .functionFree, usrs: ["s:3Lib5otheryyF"], location: Location(file: file, line: 1, column: 6)), annotation: .unused)
    }

    private func written(from results: [ScanResult], format: BaselineFormat) -> Baseline {
        Baseline.written(from: results, union: nil, format: format, projectRoot: FilePath(root))
    }

    private func roundTrip(_ baseline: Baseline) throws -> Baseline {
        try JSONDecoder().decode(Baseline.self, from: baseline.encoded())
    }

    /// The rule and the name of each result the baseline leaves.
    private func filter(_ results: [ScanResult], with baseline: Baseline, root: String? = nil) throws -> [String] {
        try OutputDeclarationFilter(configuration: configuration(root: root), logger: logger)
            .filter(results, with: baseline)
            .map { "\($0.rule.rawValue) \($0.declaration.name)" }
    }
}
