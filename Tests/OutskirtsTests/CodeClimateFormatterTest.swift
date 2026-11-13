import Configuration
import Logger
@testable import PeripheryKit
import SourceGraph
import SystemPackage
import XCTest

final class CodeClimateFormatterTest: XCTestCase {
    private let logger = Logger(quiet: true, verbose: false, colorMode: .never)

    private func result(annotation: ScanResult.Annotation) -> ScanResult {
        let file = SourceFile(path: FilePath.current.appending("Sources/Lib/Tagged.swift"), modules: ["Lib"])
        let declaration = Declaration(name: "Tagged", kind: .class, usrs: ["s:3Lib6TaggedC"], location: Location(file: file, line: 2, column: 20))
        return ScanResult(declaration: declaration, annotation: annotation)
    }

    private func format(_ results: [ScanResult]) throws -> String {
        try XCTUnwrap(CodeClimateFormatter(configuration: Configuration(), logger: logger).format(results, colored: false))
    }

    func testCodeClimateOutput_containsRequiredSpecFields() throws {
        let output = try format([
            result(annotation: .unused),
            result(annotation: .assignOnlyProperty),
        ])
        let issues = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]])

        XCTAssertEqual(issues.count, 2)
        XCTAssertEqual(issues.map { $0["check_name"] as? String }, ["unused", "assignOnlyProperty"])
        for issue in issues {
            XCTAssertEqual(issue["type"] as? String, "issue")
            XCTAssertEqual(issue["categories"] as? [String], ["Bug Risk"])
            XCTAssertEqual(issue["severity"] as? String, "major")
            XCTAssertEqual((issue["fingerprint"] as? String)?.count, 64)
            XCTAssertNotNil(issue["description"] as? String)
            let location = try XCTUnwrap(issue["location"] as? [String: Any])
            XCTAssertEqual(location["path"] as? String, "Sources/Lib/Tagged.swift")
            XCTAssertEqual(location["lines"] as? [String: Int], ["begin": 2, "end": 2])
        }
    }

    func testCodeClimateOutput_givesEachResultOfADeclarationItsOwnFingerprint() throws {
        let output = try format([
            result(annotation: .redundantProtocol(references: [], inherited: [])),
            result(annotation: .redundantPublicAccessibility(modules: ["Lib"])),
        ])
        let issues = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]])
        let fingerprints = issues.compactMap { $0["fingerprint"] as? String }

        XCTAssertEqual(fingerprints.count, 2)
        XCTAssertEqual(Set(fingerprints).count, 2)
    }

    func testCodeClimateOutput_fingerprintDoesNotDependOnWhereTheProjectLives() throws {
        func fingerprint(root: String) throws -> String? {
            let file = SourceFile(path: FilePath(root).appending("Sources/Lib/Tagged.swift"), modules: ["Lib"])
            let declaration = Declaration(name: "Tagged", kind: .class, usrs: ["s:3Lib6TaggedC"], location: Location(file: file, line: 2, column: 20))
            let formatter = CodeClimateFormatter(configuration: Configuration(), logger: logger)
            formatter.currentFilePath = FilePath(root)
            let output = try XCTUnwrap(formatter.format([ScanResult(declaration: declaration, annotation: .unused)], colored: false))
            let issues = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]])
            return issues.first?["fingerprint"] as? String
        }

        // SHA-256 of "unused\ns:3Lib6TaggedC": the same on every machine and in every checkout.
        let expected = "d7e1a91c30fac6917621a004097b432bd6b202f8d72273c3d2169b2e9dc2e9f4"
        XCTAssertEqual(try fingerprint(root: "/srv/a/project"), try fingerprint(root: "/tmp/elsewhere/checkout"))
        XCTAssertEqual(try fingerprint(root: "/srv/a/project"), expected)
    }

    func testCodeClimateOutput_isStableAcrossRuns() throws {
        let results = [result(annotation: .unused)]
        let first = try format(results)
        for _ in 0 ..< 5 {
            XCTAssertEqual(try format(results), first)
        }
    }
}
