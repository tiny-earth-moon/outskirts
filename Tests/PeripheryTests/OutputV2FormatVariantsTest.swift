import Configuration
import Foundation
import Logger
@testable import PeripheryKit
@testable import SourceGraph
import SystemPackage
import XCTest
import Yams

/// `csv-v2`, `checkstyle-v2`, `codeclimate-v2` and `gitlab-codequality-v2`: the current formats plus the output v2 id
/// and rule of each result, with the id as the fingerprint. The current formats hold neither.
final class OutputV2FormatVariantsTest: XCTestCase {
    private let logger = Logger(quiet: true, verbose: false, colorMode: .never)
    private let root = "/work/project"

    func testCsvV2_startsEveryRowWithTheIdAndRuleOfItsResult() throws {
        let rows = try format(.csvV2).split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false) }

        XCTAssertEqual(rows[0].prefix(3), ["ID", "Rule", "Kind"])
        XCTAssertEqual(rows.dropFirst().map { "\($0[0]) \($0[1])" }, expectedIdentities.map { "\($0.id) \($0.rule)" })
        XCTAssertEqual(rows.dropFirst().map { Array($0.dropFirst(2)) }, try format(.csv).split(separator: "\n").dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false) })
    }

    func testCodeClimateAndGitLabV2_takeTheirFingerprintFromTheId() throws {
        for format in [OutputFormat.codeclimateV2, .gitlabCodeQualityV2] {
            let issues = try XCTUnwrap(try Yams.load(yaml: self.format(format)) as? [[String: Any]], "\(format)")

            XCTAssertEqual(issues.map { $0["id"] as? String }, [id(of: run()), id(of: marker())], "\(format)")
            XCTAssertEqual(issues.map { $0["fingerprint"] as? String }, issues.map { $0["id"] as? String }, "\(format)")
            XCTAssertEqual(issues.map { $0["rule"] as? String }, ["unused", "redundant-protocol"], "\(format)")
        }
    }

    func testCheckstyleV2_givesEachErrorItsRuleAsSourceAndItsId() throws {
        let output = try format(.checkstyleV2)

        for identity in expectedIdentities {
            XCTAssertTrue(output.contains("source=\"\(identity.rule)\" id=\"\(identity.id)\" "), "\(identity) in \(output)")
        }
    }

    func testCurrentFormats_holdNoOutputV2Id() throws {
        for format in [OutputFormat.csv, .checkstyle, .codeclimate, .gitlabCodeQuality] {
            let output = try self.format(format)

            XCTAssertFalse(output.contains(OutputV2Id.prefix), "\(format)")
            XCTAssertFalse(output.contains("redundant-protocol"), "\(format)")
        }
    }

    // MARK: - Fixture

    /// The id and rule of each part, in the order of the formats: the unused function, the redundant protocol, then
    /// its conformance.
    private var expectedIdentities: [(id: String, rule: String)] {
        [
            (id(of: run()), "unused"),
            (id(of: marker()), "redundant-protocol"),
            (OutputV2Id.id(ofConformance: conformance()), "redundant-conformance"),
        ]
    }

    private func location(_ path: String, line: Int, column: Int) -> Location {
        Location(file: SourceFile(path: FilePath(root + "/" + path), modules: ["Lib"]), line: line, column: column)
    }

    private func run() -> ScanResult {
        ScanResult(declaration: Declaration(name: "run()", kind: .functionFree, usrs: ["s:3Lib3runyyF"], location: location("Sources/Lib/Run.swift", line: 2, column: 6)), annotation: .unused)
    }

    private func conformance() -> Reference {
        let type = Declaration(name: "Alpha", kind: .struct, usrs: ["s:3Lib5AlphaV"], location: location("Sources/Lib/Types.swift", line: 3, column: 8))
        let reference = Reference(name: "Marker", kind: .related, declarationKind: .protocol, usr: "s:3Lib6MarkerP", location: location("Sources/Lib/Types.swift", line: 3, column: 15))
        reference.parent = type
        return reference
    }

    private func marker() -> ScanResult {
        let marker = Declaration(name: "Marker", kind: .protocol, usrs: ["s:3Lib6MarkerP"], location: location("Sources/Lib/Marker.swift", line: 1, column: 10))
        return ScanResult(declaration: marker, annotation: .redundantProtocol(references: [conformance()], inherited: []))
    }

    private func id(of result: ScanResult) -> String {
        OutputV2Id.id(of: result)
    }

    private func format(_ format: OutputFormat) throws -> String {
        let configuration = Configuration()
        configuration.projectRoot = FilePath(root)
        configuration.relativeResults = true
        let formatter = format.formatter.init(configuration: configuration, logger: logger)
        formatter.currentFilePath = FilePath(root)
        return try XCTUnwrap(formatter.format([run(), marker()], colored: false))
    }
}
