@testable import Fix
import Foundation
import XCTest

final class XCStringsKeyRemoverTest: XCTestCase {
    /// A catalog laid out as Xcode writes it, one entry per (escaped) key.
    private func catalog(_ keys: [String], lineBreak: String = "\n") -> String {
        let entries = keys.map { key in
            """
                \(key) : {
                  "comment" : "Says \(key.dropFirst().dropLast())",
                  "localizations" : {
                    "fr" : {
                      "stringUnit" : {
                        "state" : "translated",
                        "value" : "x"
                      }
                    }
                  }
                }
            """
        }
        let strings = entries.isEmpty ? "{\n\n  }" : "{\n" + entries.joined(separator: ",\n") + "\n  }"
        let text = "{\n  \"sourceLanguage\" : \"en\",\n  \"strings\" : \(strings),\n  \"version\" : \"1.0\"\n}"
        return text.replacingOccurrences(of: "\n", with: lineBreak)
    }

    private func removing(_ keys: Set<String>, from text: String) throws -> String {
        try XCTUnwrap(String(validating: XCStringsKeyRemover.removing(keys, from: Array(text.utf8)), as: UTF8.self))
    }

    private func assertRefused(_ keys: Set<String>, from text: String, _ expected: XCStringsKeyRemovalError, line: UInt = #line) {
        XCTAssertThrowsError(try XCStringsKeyRemover.removing(keys, from: Array(text.utf8)), line: line) { error in
            XCTAssertEqual(error as? XCStringsKeyRemovalError, expected, line: line)
        }
    }

    func testFirstMiddleAndLastKeysLeaveTheCatalogXcodeWouldWrite() throws {
        let all = ["\"a\"", "\"b\"", "\"c\""]
        XCTAssertEqual(try removing(["a"], from: catalog(all)), catalog(["\"b\"", "\"c\""]))
        XCTAssertEqual(try removing(["b"], from: catalog(all)), catalog(["\"a\"", "\"c\""]))
        XCTAssertEqual(try removing(["c"], from: catalog(all)), catalog(["\"a\"", "\"b\""]))
    }

    func testOnlyKeyLeavesAnEmptyStringsObject() throws {
        XCTAssertEqual(try removing(["a"], from: catalog(["\"a\""])), catalog([]))
        XCTAssertEqual(try removing(["a", "b"], from: catalog(["\"a\"", "\"b\""])), catalog([]))
    }

    func testSeveralKeysIncludingNeighbours() throws {
        let all = ["\"a\"", "\"b\"", "\"c\"", "\"d\"", "\"e\""]
        XCTAssertEqual(try removing(["a", "b", "d"], from: catalog(all)), catalog(["\"c\"", "\"e\""]))
        XCTAssertEqual(try removing(["d", "e"], from: catalog(all)), catalog(["\"a\"", "\"b\"", "\"c\""]))
    }

    func testEscapedUnicodeAndEmojiKeysMatchTheirDecodedText() throws {
        let all = [#""Say \"hi\"""#, #""back\\slash\nline""#, #""café""#, #""😀 smile""#, "\"🎉 party\"", "\"plain\""]
        let text = catalog(all)
        let removed: Set = ["Say \"hi\"", "back\\slash\nline", "café", "😀 smile", "🎉 party"]

        XCTAssertEqual(try removing(removed, from: text), catalog(["\"plain\""]))
    }

    func testKeyThatIsAPrefixOfAnotherOrAppearsInAnotherEntry() throws {
        let all = ["\"Done\"", "\"Done!\"", "\"Not Done\""]
        XCTAssertEqual(try removing(["Done"], from: catalog(all)), catalog(["\"Done!\"", "\"Not Done\""]))
        // "Says Done" appears in every comment: only the member whose key is "Done!" goes.
        XCTAssertEqual(try removing(["Done!"], from: catalog(all)), catalog(["\"Done\"", "\"Not Done\""]))
    }

    func testMissingKeyRefusesTheWholeFile() {
        assertRefused(["a", "zz"], from: catalog(["\"a\"", "\"b\""]), .keysNotFound(["zz"]))
        assertRefused(["a"], from: "{\n  \"version\" : \"1.0\"\n}", .keysNotFound(["a"]))
    }

    func testDuplicateKeyRefusesTheFile() {
        assertRefused(["a"], from: catalog(["\"a\"", "\"b\"", "\"a\""]), .duplicateKey("a"))
        assertRefused(["a"], from: catalog(["\"caf\\u00e9\"", "\"café\"", "\"a\""]), .duplicateKey("café"))
    }

    func testCRLFCatalogKeepsItsLineBreaks() throws {
        let all = ["\"a\"", "\"b\"", "\"c\""]
        XCTAssertEqual(try removing(["b"], from: catalog(all, lineBreak: "\r\n")), catalog(["\"a\"", "\"c\""], lineBreak: "\r\n"))
        XCTAssertEqual(try removing(["c"], from: catalog(all, lineBreak: "\r\n")), catalog(["\"a\"", "\"b\""], lineBreak: "\r\n"))
        XCTAssertEqual(try removing(["a", "b", "c"], from: catalog(all, lineBreak: "\r\n")), catalog([], lineBreak: "\r\n"))
    }

    func testCompactAndUnusualSpacingStayValid() throws {
        XCTAssertEqual(try removing(["b"], from: #"{"strings":{"a":{},"b":{"x":[1,2]},"c":{}}}"#), #"{"strings":{"a":{},"c":{}}}"#)
        XCTAssertEqual(try removing(["a", "c"], from: #"{"strings":{"a":{},"b":1 , "c":{}}}"#), #"{"strings":{"b":1}}"#)
        XCTAssertEqual(try removing(["a"], from: #"{"strings":{"a":{}}}"#), #"{"strings":{}}"#)
        XCTAssertEqual(try removing(["a"], from: "{ \"strings\" :\t{ \"a\" : true ,\n\"b\" : null } }"), "{ \"strings\" :\t{ \"b\" : null } }")
    }

    func testMalformedOrUnexpectedCatalogsAreRefused() {
        assertRefused(["a"], from: #"{"strings":{"a":{},}}"#, .malformedJSON(offset: 19))
        assertRefused(["a"], from: #"{"strings":{"a":{}}} x"#, .malformedJSON(offset: 21))
        assertRefused(["a"], from: "\u{FEFF}" + #"{"strings":{"a":{}}}"#, .unexpectedStructure("the catalog is not a JSON object"))
        assertRefused(["a"], from: #"{"strings":[]}"#, .unexpectedStructure("the strings member is not a JSON object"))
        assertRefused(["a"], from: #"{"strings":{"a":{}},"strings":{}}"#, .duplicateKey("strings"))
        assertRefused(["a"], from: #"{"strings":{"a":01}}"#, .malformedJSON(offset: 17))
        assertRefused(["a"], from: #"{"strings":{"\ud83d":1}}"#, .malformedJSON(offset: 19))
        assertRefused(["a"], from: "{\"strings\":{\"a\":\"\u{1}\"}}", .malformedJSON(offset: 17))
        assertRefused(["a"], from: #"{"strings":{"a":"x"#, .malformedJSON(offset: 18))
    }

    func testDeeplyNestedValueIsRefused() {
        let nested = String(repeating: "[", count: 600) + String(repeating: "]", count: 600)
        assertRefused(["a"], from: #"{"strings":{"a":"# + nested + "}}", .unexpectedStructure("nested too deeply"))
    }

    func testEmptyKeySetLeavesTheBytesAsTheyAre() throws {
        let invalid = "not json"
        XCTAssertEqual(try removing([], from: invalid), invalid)
    }

    func testResultReadsBackAsTheOriginalWithoutTheKeys() throws {
        let text = catalog(["\"a\"", "\"b\""])
        let result = try removing(["a"], from: text)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        let strings = try XCTUnwrap(decoded["strings"] as? [String: Any])

        XCTAssertEqual(Set(strings.keys), ["b"])
        XCTAssertEqual(decoded["version"] as? String, "1.0")
    }
}
