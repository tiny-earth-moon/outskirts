import Foundation
@testable import TestShared
import XCTest

/// Periphery 3.8 compatibility contract for the output formats and the scan exit status: the `outskirts` executable
/// scans `package/`, the package 3.8.0 scanned to produce `output/`, and must print the same thing. The text formats
/// must match byte for byte; in the JSON formats every 3.8 field must still be there with the same value (new fields
/// are allowed). The byte for byte output of the JSON formats is pinned separately by the goldens of `FormatterTests`.
///
/// A failing test here is a 3.x compatibility break that needs a deliberate decision, not a fixture or test update.
final class Periphery38OutputContractTest: XCTestCase {
    private static let package = Result { try copyPackage("package") }
    private static let packageWithoutResults = Result { try copyPackage("package-no-results") }

    private var outputDirectory: URL!

    // swiftlint:disable:next static_over_final_class
    override class func tearDown() {
        for package in [package, packageWithoutResults] {
            if let url = try? package.get() {
                try? FileManager.default.removeItem(at: url)
            }
        }

        super.tearDown()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        outputDirectory = try makeTemporaryDirectory("periphery-38-output")
        addTeardownBlock { [outputDirectory] in
            if let outputDirectory {
                try? FileManager.default.removeItem(at: outputDirectory)
            }
        }
    }

    func testXcodeOutputIsThatOf38() throws {
        try assertSameText("xcode")
    }

    func testCheckstyleOutputIsThatOf38() throws {
        try assertSameText("checkstyle")
    }

    func testGitHubActionsOutputIsThatOf38() throws {
        try assertSameText("github-actions")
    }

    func testGitHubMarkdownOutputIsThatOf38() throws {
        try assertSameText("github-markdown")
    }

    func testCsvHeaderAndRowCountAreThoseOf38() throws {
        let expected = try expectedLines("csv")
        let output = try lines(scan("csv"))

        XCTAssertEqual(output.first, expected.first)
        XCTAssertEqual(output.count, expected.count)
    }

    /// 3.8 wrote the modifiers in the `Attributes` column and the attributes in the `Modifiers` column; outskirts puts
    /// each in its own column. Known incompatibility (a fixed 3.8 bug), kept on purpose.
    func testCsvRowsAreThoseOf38() throws {
        let expected = try expectedLines("csv")
        let output = try lines(scan("csv"))

        try expectKnownIncompatibility("the CSV Modifiers and Attributes columns are swapped in 3.8") {
            XCTAssertEqual(output, expected)
        }
    }

    func testJsonOutputKeepsEvery38Field() throws {
        try assertKeepsEvery38Field("json")
    }

    func testCodeClimateOutputKeepsEvery38Field() throws {
        try assertKeepsEvery38Field("codeclimate")
    }

    func testGitLabCodeQualityOutputKeepsEvery38Field() throws {
        try assertKeepsEvery38Field("gitlab-codequality")
    }

    func testExitStatusesAreThoseOf38() throws {
        let codes = try Periphery38Contract.decode(Contract38ExitCodes.self, from: "exit-codes.json")

        XCTAssertEqual(try run([], in: Self.package).status, codes.scan.resultsWithoutStrict)
        XCTAssertEqual(try run(["--strict"], in: Self.package).status, codes.scan.resultsWithStrict)
        XCTAssertEqual(try run(["--strict", "--retain-public"], in: Self.packageWithoutResults).status, codes.scan.noResults)
        XCTAssertEqual(try run(["--config", "missing.yml"], in: Self.package).status, codes.scan.missingConfigurationFile)
        XCTAssertEqual(try run(["--not-an-option"], in: Self.package).status, codes.scan.unknownOption)
    }

    // MARK: - Private

    private static func copyPackage(_ name: String) throws -> URL {
        let destination = uniqueTemporaryURL("periphery-38-\(name)").resolvingSymlinksInPath()
        try FileManager.default.copyItem(at: Periphery38Contract.url(name), to: destination)
        return destination
    }

    private func assertSameText(_ format: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try String(contentsOf: Periphery38Contract.url("output/\(format).txt"), encoding: .utf8)

        XCTAssertEqual(try String(bytes: scan(format), encoding: .utf8), expected, "the \(format) output differs from 3.8", file: file, line: line)
    }

    private func assertKeepsEvery38Field(_ format: String) throws {
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: Periphery38Contract.url("output/\(format).txt")))
        let output = try JSONSerialization.jsonObject(with: scan(format))

        XCTAssertEqual(Self.missing(expected, in: output, at: format), [])
    }

    /// The paths of the values of `expected` that `actual` lacks or holds with another value; arrays must have the
    /// same length, objects may have more keys.
    private static func missing(_ expected: Any, in actual: Any, at path: String) -> [String] {
        switch expected {
        case let expected as [String: Any]:
            guard let actual = actual as? [String: Any] else { return ["\(path) is no longer an object"] }

            return expected.keys.sorted().flatMap { key in
                actual[key].map { missing(expected[key]!, in: $0, at: "\(path).\(key)") } ?? ["\(path).\(key) is gone"]
            }
        case let expected as [Any]:
            guard let actual = actual as? [Any], actual.count == expected.count else { return ["\(path) changed its length"] }

            return zip(expected, actual).enumerated().flatMap { missing($1.0, in: $1.1, at: "\(path)[\($0)]") }
        default:
            return (expected as? NSObject)?.isEqual(actual) == true ? [] : ["\(path) changed from \(expected) to \(actual)"]
        }
    }

    private func expectedLines(_ format: String) throws -> [String] {
        try lines(Data(contentsOf: Periphery38Contract.url("output/\(format).txt")))
    }

    private func lines(_ data: Data) -> [String] {
        (String(bytes: data, encoding: .utf8) ?? "").components(separatedBy: "\n")
    }

    private func scan(_ format: String) throws -> Data {
        let output = try run(["--format", format, "--quiet", "--relative-results"], in: Self.package)
        XCTAssertEqual(output.status, 0, String(bytes: output.stderr, encoding: .utf8) ?? "")
        return output.stdout
    }

    private func run(_ arguments: [String], in package: Result<URL, Error>) throws -> CapturedProcessOutput {
        try runCapturingOutput(
            locatePeripheryExecutable(near: Self.self),
            ["scan", "--disable-update-check"] + arguments,
            currentDirectoryURL: package.get(),
            outputDirectory: outputDirectory,
            timeout: (300, "outskirts")
        )
    }

    /// Runs assertions that fail because of a known 3.8 incompatibility: the test fails once they pass, so that the
    /// entry is removed. XCTest without `XCTExpectFailure` (Linux) skips them.
    private func expectKnownIncompatibility(_ reason: String, _ body: () throws -> Void) throws {
        #if canImport(ObjectiveC)
            let options = XCTExpectedFailure.Options()
            options.isStrict = true
            try XCTExpectFailure("Known Periphery 3.8 incompatibility: \(reason)", options: options) {
                try body()
            }
        #else
            throw XCTSkip("Known Periphery 3.8 incompatibility: \(reason)")
        #endif
    }
}
