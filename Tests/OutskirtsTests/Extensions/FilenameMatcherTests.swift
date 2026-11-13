import FilenameMatcher
import Foundation
import XCTest

final class FilenameMatcherTests: XCTestCase {
    func testRelativePatterns() {
        assertMatch(filename: "/Sources/File.swift", relativeTo: "/", pattern: "/Sources/File.swift")
        assertMatch(filename: "/Sources/File.swift", relativeTo: "/", pattern: "Sources/File.swift")
        assertMatch(filename: "/Sources/File.swift", relativeTo: "/", pattern: "*/Sources/File.swift")
        assertMatch(filename: "/Sources/File.swift", relativeTo: "/", pattern: "**/Sources/File.swift")

        assertMatch(filename: "/a/b/Sources/File.swift", relativeTo: "/", pattern: "*/Sources/File.swift")
        assertMatch(filename: "/a/b/Sources/File.swift", relativeTo: "/", pattern: "**/Sources/File.swift")
        assertMatch(filename: "/a/b/Sources/File.swift", relativeTo: "/", pattern: "a/**/File.swift")

        assertMatch(filename: "/a/b/Sources/File.swift", relativeTo: "/a", pattern: "*/Sources/File.swift")
        assertMatch(filename: "/a/b/Sources/File.swift", relativeTo: "/a", pattern: "**/Sources/File.swift")
        assertMatch(filename: "/a/b/c/Sources/File.swift", relativeTo: "/b", pattern: "/**/File.swift")

        assertMatch(filename: "/a/Sources/File.swift", relativeTo: "/a/b", pattern: "../Sources/File.swift")
        assertMatch(filename: "/a/Sources/File.swift", relativeTo: "/a/b/c/d", pattern: "../../../Sources/*.swift")
        assertMatch(filename: "/a/b/c/d/Sources/File.swift", relativeTo: "/a/b", pattern: "../*/Sources/File.swift")
        assertMatch(filename: "/a/b/c/d/Sources/File.swift", relativeTo: "/a/b", pattern: "../**/File.swift")
        assertMatch(filename: "/a/b/c/d/Sources/File.swift", relativeTo: "/a/b/c", pattern: "../../**/File.swift")

        assertNotMatch(filename: "/Sources/File.swift", relativeTo: "/", pattern: "/x/**/Sources/File.swift")
        assertNotMatch(filename: "/Sources/File.swift", relativeTo: "/", pattern: "../../**/File.swift")
        assertNotMatch(filename: "/a/Sources/File.swift", relativeTo: "/", pattern: "/Sources/File.swift")
    }

    func testRelativePattern_underRootWithGlobMetacharacters_matchesLiterally() {
        for base in ["/x[1]/y{a}/z*", "/App [beta]", "/b[1]/p", "/what?"] {
            assertMatch(filename: "\(base)/Sources/File.swift", relativeTo: base, pattern: "Sources/File.swift")
            assertMatch(filename: "\(base)/Sources/File.swift", relativeTo: base, pattern: "Sources/*.swift")
            assertMatch(filename: "\(base)/a/Sources/File.swift", relativeTo: "\(base)/a", pattern: "../**/File.swift")
        }

        assertNotMatch(filename: "/b1/p/Sources/File.swift", relativeTo: "/b[1]/p", pattern: "Sources/File.swift")
        assertNotMatch(filename: "/zzz/Sources/File.swift", relativeTo: "/z*", pattern: "Sources/File.swift")
        assertNotMatch(filename: "/whatx/Sources/File.swift", relativeTo: "/what?", pattern: "Sources/File.swift")
    }

    // MARK: - Private

    private func assertMatch(filename: String, relativeTo base: String, pattern: String, file: StaticString = #file, line: UInt = #line) {
        let matcher = FilenameMatcher(relativePattern: pattern, to: base, caseSensitive: false)
        XCTAssertTrue(matcher.match(filename: filename), file: file, line: line)
    }

    private func assertNotMatch(filename: String, relativeTo base: String, pattern: String, file: StaticString = #file, line: UInt = #line) {
        let matcher = FilenameMatcher(relativePattern: pattern, to: base, caseSensitive: false)
        XCTAssertFalse(matcher.match(filename: filename), file: file, line: line)
    }
}
