@testable import Fix
import XCTest

/// The hunks of `UnifiedDiff`, each compared with the output of `diff -u` for the same files.
final class UnifiedDiffTest: XCTestCase {
    private func numbers(_ range: ClosedRange<Int>, replacing replaced: [Int: String] = [:]) -> String {
        range.map { replaced[$0] ?? "\($0)" }.joined(separator: "\n") + "\n"
    }

    private func diff(_ old: String, _ new: String) -> String {
        UnifiedDiff.diff(old: old, new: new, oldPath: "a/F.swift", newPath: "b/F.swift")
    }

    private func expected(_ lines: [String]) -> String {
        (["--- a/F.swift", "+++ b/F.swift"] + lines).joined(separator: "\n") + "\n"
    }

    func testIdenticalTextsHaveNoDiff() {
        XCTAssertEqual(diff(numbers(1 ... 5), numbers(1 ... 5)), "")
    }

    func testChangesFurtherApartThanTwiceTheContextAreSeparateHunks() {
        let new = numbers(1 ... 13, replacing: [2: "two", 10: "ten"])

        XCTAssertEqual(diff(numbers(1 ... 13), new), expected([
            "@@ -1,5 +1,5 @@", " 1", "-2", "+two", " 3", " 4", " 5",
            "@@ -7,7 +7,7 @@", " 7", " 8", " 9", "-10", "+ten", " 11", " 12", " 13",
        ]))
    }

    func testChangesTwiceTheContextApartShareAHunk() {
        let new = numbers(1 ... 12, replacing: [2: "two", 9: "nine"])

        XCTAssertEqual(diff(numbers(1 ... 12), new), expected([
            "@@ -1,12 +1,12 @@", " 1", "-2", "+two", " 3", " 4", " 5", " 6", " 7", " 8", "-9", "+nine", " 10", " 11", " 12",
        ]))
    }

    func testChangesAtTheStartAndTheEndOfALongFile() {
        let new = numbers(1 ... 20, replacing: [2: "two", 18: "eighteen"])

        XCTAssertEqual(diff(numbers(1 ... 20), new), expected([
            "@@ -1,5 +1,5 @@", " 1", "-2", "+two", " 3", " 4", " 5",
            "@@ -15,6 +15,6 @@", " 15", " 16", " 17", "-18", "+eighteen", " 19", " 20",
        ]))
    }

    func testRemovedFirstLine() {
        XCTAssertEqual(diff(numbers(1 ... 5), numbers(2 ... 5)), expected(["@@ -1,4 +1,3 @@", "-1", " 2", " 3", " 4"]))
    }

    func testInsertedLineCountsOnlyInTheNewRange() {
        let new = numbers(1 ... 10).replacingOccurrences(of: "5\n", with: "5\nnew\n")

        XCTAssertEqual(diff(numbers(1 ... 10), new), expected(["@@ -3,6 +3,7 @@", " 3", " 4", " 5", "+new", " 6", " 7", " 8"]))
    }

    func testPureInsertionIntoAnEmptyFileHasAnEmptyOldRange() {
        XCTAssertEqual(diff("", "x\n"), expected(["@@ -0,0 +1 @@", "+x"]))
    }

    func testMissingFinalNewlineIsMarked() {
        XCTAssertEqual(diff("1\n2\n3\n4\n5", "1\n2\n3\n4\nfive"), expected([
            "@@ -2,4 +2,4 @@", " 2", " 3", " 4", "-5", "\\ No newline at end of file", "+five", "\\ No newline at end of file",
        ]))
    }

    func testCRLFLinesKeepTheirTerminator() {
        XCTAssertEqual(
            diff("a\r\nb\r\nc\r\n", "a\r\nB\r\nc\r\n"),
            "--- a/F.swift\n+++ b/F.swift\n@@ -1,3 +1,3 @@\n a\r\n-b\r\n+B\r\n c\r\n"
        )
    }
}
