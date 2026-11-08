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

    func testCodeClimateOutput_isStableAcrossRuns() throws {
        let results = [result(annotation: .unused)]
        let first = try format(results)
        for _ in 0 ..< 5 {
            XCTAssertEqual(try format(results), first)
        }
    }

    private func fingerprints(_ formatter: OutputFormatter, _ results: [ScanResult]) throws -> [String] {
        let output = try XCTUnwrap(formatter.format(results, colored: false))
        let issues = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]])
        return try issues.map { try XCTUnwrap($0["fingerprint"] as? String) }
    }

    private var qualityFormatters: [OutputFormatter] {
        [
            CodeClimateFormatter(configuration: Configuration(), logger: logger),
            GitLabCodeQualityFormatter(configuration: Configuration(), logger: logger),
        ]
    }

    func testFingerprint_differsByResultKindOnSameDeclaration() throws {
        for formatter in qualityFormatters {
            let values = try fingerprints(formatter, [
                result(annotation: .unused),
                result(annotation: .assignOnlyProperty),
                result(annotation: .redundantPublicAccessibility(modules: ["Lib"])),
            ])
            XCTAssertEqual(Set(values).count, 3, "\(type(of: formatter))")
        }
    }

    func testFingerprint_isStableAcrossRunsAndKnownValue() throws {
        for formatter in qualityFormatters {
            let first = try fingerprints(formatter, [result(annotation: .unused)])
            XCTAssertEqual(try fingerprints(formatter, [result(annotation: .unused)]), first)
            XCTAssertEqual(first, [SHA256.hexDigest(of: Data("unused\ns:3Lib6TaggedC".utf8))])
        }
    }

    func testLinesEnd_usesDeclarationRangeEnd() throws {
        let ranged = result(annotation: .unused)
        ranged.declaration.range = DeclarationRange(start: SourcePosition(line: 2, column: 1), end: SourcePosition(line: 9, column: 2))
        for formatter in qualityFormatters {
            let output = try XCTUnwrap(formatter.format([ranged], colored: false))
            let issues = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]])
            let location = try XCTUnwrap(issues.first?["location"] as? [String: Any])
            XCTAssertEqual(location["lines"] as? [String: Int], ["begin": 2, "end": 9], "\(type(of: formatter))")
        }
    }

    func testGitLabCodeQualityOutput_hasLinesBeginAndEnd() throws {
        let formatter = GitLabCodeQualityFormatter(configuration: Configuration(), logger: logger)
        let output = try XCTUnwrap(formatter.format([result(annotation: .unused)], colored: false))
        let issues = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]])
        let location = try XCTUnwrap(issues.first?["location"] as? [String: Any])
        XCTAssertEqual(location["lines"] as? [String: Int], ["begin": 2, "end": 2])
    }
}
