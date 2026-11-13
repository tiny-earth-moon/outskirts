import Configuration
import Logger
@testable import PeripheryKit
import SourceGraph
import SystemPackage
import XCTest

final class GitLabCodeQualityFormatterTest: XCTestCase {
    private let logger = Logger(quiet: true, verbose: false, colorMode: .never)

    private func issues(_ annotations: [ScanResult.Annotation]) throws -> [[String: Any]] {
        let file = SourceFile(path: FilePath.current.appending("Sources/Lib/Tagged.swift"), modules: ["Lib"])
        let declaration = Declaration(name: "Tagged", kind: .protocol, usrs: ["s:3Lib6TaggedP"], location: Location(file: file, line: 2, column: 17))
        let results = annotations.map { ScanResult(declaration: declaration, annotation: $0) }
        let output = try XCTUnwrap(GitLabCodeQualityFormatter(configuration: Configuration(), logger: logger).format(results, colored: false))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]])
    }

    /// GitLab shows the findings of identical fingerprints as a single entry.
    func testGitLabCodeQualityOutput_givesEachResultOfADeclarationItsOwnFingerprint() throws {
        let issues = try issues([
            .redundantProtocol(references: [], inherited: []),
            .redundantPublicAccessibility(modules: ["Lib"]),
        ])
        let fingerprints = issues.compactMap { $0["fingerprint"] as? String }

        XCTAssertEqual(fingerprints.count, 2)
        XCTAssertEqual(Set(fingerprints).count, 2)
    }

    func testGitLabCodeQualityOutput_fingerprintIsStableAcrossRuns() throws {
        let first = try issues([.unused]).first?["fingerprint"] as? String

        XCTAssertNotNil(first)
        for _ in 0 ..< 5 {
            XCTAssertEqual(try issues([.unused]).first?["fingerprint"] as? String, first)
        }
    }

    func testGitLabCodeQualityOutput_locationHasTheBeginLine() throws {
        let location = try XCTUnwrap(issues([.unused]).first?["location"] as? [String: Any])

        XCTAssertEqual(location["lines"] as? [String: Int], ["begin": 2])
    }
}
