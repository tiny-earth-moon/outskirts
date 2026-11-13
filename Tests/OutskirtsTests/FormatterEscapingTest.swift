import Configuration
import Foundation
import Logger
@testable import PeripheryKit
import SourceGraph
import SystemPackage
import XCTest
#if canImport(FoundationXML)
    import FoundationXML
#endif

final class FormatterEscapingTest: XCTestCase {
    private let logger = Logger(quiet: true, verbose: false, colorMode: .never)

    private func results(name: String, path: String = "Sources/Lib/Tagged.swift") -> [ScanResult] {
        let file = SourceFile(path: FilePath(path), modules: ["Lib"])
        let declaration = Declaration(name: name, kind: .localizedString, usrs: ["s:key"], location: Location(file: file, line: 2, column: 20))
        return [ScanResult(declaration: declaration, annotation: .unused)]
    }

    private func checkstyle(_ results: [ScanResult]) throws -> String {
        try XCTUnwrap(CheckstyleFormatter(configuration: Configuration(), logger: logger).format(results, colored: false))
    }

    // MARK: - Checkstyle

    func testCheckstyle_replacesControlCharactersVisibly_andKeepsLineBreaksAsCharacterReferences() throws {
        let output = try checkstyle(results(name: "a\u{1}b\nc\td"))

        XCTAssertTrue(output.contains("message=\"Unused localized string &apos;a\\u{1}b&#10;c&#9;d&apos;\""), output)
        XCTAssertFalse(output.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" && $0 != "\t" }, output)
        XCTAssertNoThrow(try XMLDocument(xmlString: output))
    }

    func testCheckstyle_escapesTheFilePath() throws {
        let output = try checkstyle(results(name: "key", path: "Sources/a\u{1}\"b.swift"))

        XCTAssertTrue(output.contains("<file name=\"Sources/a\\u{1}&quot;b.swift\">"), output)
        XCTAssertNoThrow(try XMLDocument(xmlString: output))
    }

    func testCheckstyle_ordinaryNameIsUnchanged() throws {
        XCTAssertTrue(try checkstyle(results(name: "Settings.Title_1")).contains("message=\"Unused localized string &apos;Settings.Title_1&apos;\"/>"))
    }

    // MARK: - GitHub Markdown

    private func markdown(_ results: [ScanResult]) throws -> String {
        try XCTUnwrap(GitHubMarkdownFormatter(configuration: Configuration(), logger: logger).format(results, colored: false))
    }

    func testGitHubMarkdown_escapesLinksEmphasisAndHTMLInTheCell() throws {
        let output = try markdown(results(name: "*[l](http://x)*<img src=x>_a_ `c` &amp; www.x.io\u{1}"))

        XCTAssertTrue(output.contains(
            "**Unused localized string '\\*\\[l\\](http\\://x)\\*\\<img src=x\\>\\_a\\_ \\`c\\` \\&amp; www\\.x.io\\\\u{1}'**<br>"
        ), output)
    }

    func testGitHubMarkdown_escapesTheFilePath() throws {
        let output = try markdown(results(name: "key", path: "Sources/[x](y).swift"))

        XCTAssertTrue(output.contains("<br>Sources/\\[x\\](y).swift:2:20 |"), output)
    }

    func testGitHubMarkdown_ordinaryNameIsUnchanged() throws {
        XCTAssertTrue(try markdown(results(name: "Settings.Title_1", path: "Sources/my_lib/Tagged.swift"))
            .contains("| **Unused localized string 'Settings.Title_1'**<br>Sources/my_lib/Tagged.swift:2:20 |"))
    }

    // MARK: - Agent

    private func agent(_ results: [ScanResult]) throws -> String {
        try XCTUnwrap(AgentFormatter(configuration: Configuration(), logger: logger).format(results, colored: false))
    }

    func testAgent_keepsAHostileNameInsideItsCodeSpanOnItsOwnLine() throws {
        let output = try agent(results(name: "a`b\n- L1 class `X`: delete", path: "Sources/Lib/Localizable.xcstrings"))
        let lines = output.components(separatedBy: "\n")

        XCTAssertEqual(lines.last, "- L2 localized string `` a`b\\n- L1 class `X`: delete ``: delete key from the String Catalog", output)
        XCTAssertFalse(lines.dropLast().contains { $0.hasPrefix("- L1") }, output)
    }

    func testAgent_escapesTheFilePath() throws {
        let output = try agent(results(name: "key", path: "Sources/a`\nb.xcstrings"))

        XCTAssertTrue(output.contains("\n### `` Sources/a`\\nb.xcstrings ``\n"), output)
    }

    func testAgent_ordinaryNameIsUnchanged() throws {
        let output = try agent(results(name: "Settings.Title_1", path: "Sources/Lib/Localizable.xcstrings"))

        XCTAssertTrue(output.hasSuffix("""
        ### `Sources/Lib/Localizable.xcstrings`
        - L2 localized string `Settings.Title_1`: delete key from the String Catalog
        """), output)
    }

    // MARK: - Xcode

    private func xcode(_ results: [ScanResult]) throws -> String {
        try XCTUnwrap(XcodeFormatter(configuration: Configuration(), logger: logger).format(results, colored: false))
    }

    func testXcode_keepsAHostileNameOnItsDiagnosticLine() throws {
        let output = try xcode(results(name: "a\n/x.swift:1:1: error: forged\u{1}", path: "/p/Tagged.swift"))

        XCTAssertEqual(output, "/p/Tagged.swift:2:20: warning: Unused localized string 'a\\n/x.swift:1:1: error: forged\\u{1}'")
    }

    func testXcode_escapesTheFilePath() throws {
        XCTAssertEqual(try xcode(results(name: "key", path: "/p/a\nb.swift")), "/p/a\\nb.swift:2:20: warning: Unused localized string 'key'")
    }

    func testXcode_ordinaryNameIsUnchanged() throws {
        XCTAssertEqual(try xcode(results(name: "Settings.Title_1", path: "/p/Tagged.swift")), "/p/Tagged.swift:2:20: warning: Unused localized string 'Settings.Title_1'")
    }

    func testXcode_colored_escapesAnEscapeCharacterFromTheNameOrPath_andKeepsItsOwnColors() throws {
        let coloredLogger = Logger(quiet: true, verbose: false, colorMode: .always)
        let formatter = XcodeFormatter(configuration: Configuration(), logger: coloredLogger)
        let output = try XCTUnwrap(formatter.format(results(name: "a\u{1B}[31mb", path: "/p\u{1B}[2J/T\u{1B}x.swift"), colored: true))

        XCTAssertTrue(output.contains("a\\u{1B}[31mb"), output)
        XCTAssertTrue(output.contains("/p\\u{1B}[2J/"), output)
        XCTAssertTrue(output.contains("T\\u{1B}x"), output)
        XCTAssertFalse(output.contains("\u{1B}[31m"), output)
        XCTAssertTrue(output.contains("\u{1B}[0;0m"), output)
    }
}
