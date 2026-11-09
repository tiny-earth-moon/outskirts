@testable import Fix
import SwiftSyntax
import XCTest

/// How `outskirts fix` reads `outskirts:` and `periphery:` comment commands.
final class FixCommentCommandTest: XCTestCase {
    func testDeclarationCommentCommand() {
        XCTAssertTrue(TriviaPiece.lineComment("// periphery:ignore").isDeclarationCommentCommand)
        XCTAssertTrue(TriviaPiece.lineComment("// outskirts:ignore - reason").isDeclarationCommentCommand)
        XCTAssertTrue(TriviaPiece.blockComment("/* periphery:ignore:parameters a */").isDeclarationCommentCommand)
        XCTAssertTrue(TriviaPiece.docLineComment("/// outskirts:ignore").isDeclarationCommentCommand)
        XCTAssertFalse(TriviaPiece.lineComment("// periphery:ignore:all").isDeclarationCommentCommand)
        XCTAssertFalse(TriviaPiece.lineComment("// outskirts:ignore:all - reason").isDeclarationCommentCommand)
        XCTAssertFalse(TriviaPiece.lineComment("// just a comment").isDeclarationCommentCommand)
        XCTAssertFalse(TriviaPiece.spaces(1).isDeclarationCommentCommand)
    }

    func testIgnoreCommand() {
        XCTAssertEqual(IgnoreCommand(comment: .lineComment("// periphery:ignore")), .declaration)
        XCTAssertEqual(IgnoreCommand(comment: .blockComment("/* outskirts:ignore - why */")), .declaration)
        XCTAssertEqual(IgnoreCommand(comment: .lineComment("// periphery:ignore:parameters x,y")), .parameters(["x", "y"]))
        XCTAssertEqual(IgnoreCommand(comment: .lineComment("// outskirts:ignore:parameters a,b - why")), .parameters(["a", "b"]))
        XCTAssertNil(IgnoreCommand(comment: .lineComment("// periphery:ignore:parameters")))
        XCTAssertNil(IgnoreCommand(comment: .lineComment("// periphery:ignore:all")))
        XCTAssertNil(IgnoreCommand(comment: .lineComment("// periphery:retain")))
        XCTAssertNil(IgnoreCommand(comment: .lineComment("// ignore")))
        XCTAssertNil(IgnoreCommand(comment: .newlines(1)))
    }
}
