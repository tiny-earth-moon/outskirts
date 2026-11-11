import Configuration
import Foundation
@testable import SourceGraph
import SwiftSyntax
@testable import SyntaxAnalysis
import SystemPackage
@testable import TestShared
import XCTest

/// Periphery 3.8 compatibility contract for the source comment commands: every `periphery:` command of 3.8
/// (`ignore`, `ignore:all`, `ignore:parameters`, `override`, with a trailing `- reason`) still parses to the same
/// command, from `Tests/Fixtures/Contract/periphery-3.8/comment-commands.json`, and still retains what 3.8 retained,
/// on the retention fixtures that cover them.
///
/// A failing test here is a 3.x compatibility break that needs a deliberate decision, not a fixture or test update.
final class Periphery38CommentCommandContractTest: FixtureSourceGraphTestCase {
    func testEveryCommentCommandOf38ParsesToTheSameCommand() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Periphery38
            .deletingLastPathComponent() // OutskirtsTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Fixtures/Contract/periphery-3.8/comment-commands.json")
        let contract = try JSONDecoder().decode(CommentCommandContract.self, from: Data(contentsOf: url))

        XCTAssertEqual(contract.commands.count, 18)
        for command in contract.commands {
            let parsed = CommentCommand.parseCommands(in: Trivia(pieces: [Self.triviaPiece(command.comment)]))

            XCTAssertEqual(parsed.map { Self.normalized($0.description) }, command.parsed.map { [Self.normalized($0)] } ?? [], command.comment)
        }
    }

    func testIgnoreAndIgnoreParametersStillRetain() {
        analyzeRetentionFixture("testIgnoreComments", retainPublic: true, additionalFiles: [
            FixturesProjectPath.appending("Sources/UnusedModuleFixtures/UnusedModuleDeclaration.swift"),
        ]) {
            assertReferenced(.module("UnusedModuleFixtures"))
            assertReferenced(.class("Fixture113")) {
                self.assertReferenced(.functionMethodInstance("someFunc(param:)")) {
                    self.assertReferenced(.varParameter("param"))
                }
            }
            assertReferenced(.class("Fixture114")) {
                self.assertReferenced(.functionMethodInstance("someFunc(a:b:c:)")) {
                    self.assertReferenced(.varParameter("b"))
                    self.assertReferenced(.varParameter("c"))
                }
            }
            assertReferenced(.class("FixtureClass116")) {
                self.assertReferenced(.functionMethodInstance("someFunc()"))
                self.assertReferenced(.varInstance("commentWithTrailingDescription"))
            }
        }
    }

    func testIgnoreAllStillRetainsTheWholeFile() {
        analyzeRetentionFixture("testIgnoreAllComment", retainPublic: false) {
            assertReferenced(.class("Fixture115")) {
                self.assertReferenced(.functionMethodInstance("someFunc(param:)")) {
                    self.assertReferenced(.varParameter("param"))
                }
            }
            assertReferenced(.class("Fixture116"))
        }
    }

    func testOverrideStillSetsTheKindAndLocation() {
        analyzeRetentionFixture("testCommentCommandOverride", retainPublic: true) {
            assertOverrides(.class("FixtureClass136"), [
                .location(FilePath.current.pushing("some/other/file.swift"), 12, 34),
                .kind("banana"),
            ])
            assertOverrides(.class("FixtureClass137"), [
                .location("/absolute/path/file.swift", 56, 78),
            ])
        }
    }

    // MARK: - Private

    /// Indexes one of the existing retention fixtures, which `analyze` cannot reach from another test case.
    private func analyzeRetentionFixture(_ name: String, retainPublic: Bool, additionalFiles: [FilePath] = [], testBlock: () -> Void) {
        let configuration = Configuration()
        configuration.retainPublic = retainPublic
        configuration.buildFilenameMatchers()
        Self.index(sourceFiles: [FixturesProjectPath.appending("Sources/RetentionFixtures/\(name).swift")] + additionalFiles, configuration: configuration)
        testBlock()
    }

    /// 3.8 listed the `override` parameters in no particular order.
    private static func normalized(_ description: String) -> String {
        guard description.hasPrefix("override ") else { return description }

        return "override " + description.dropFirst("override ".count).split(separator: " ").sorted().joined(separator: " ")
    }

    private static func triviaPiece(_ comment: String) -> TriviaPiece {
        if comment.hasPrefix("///") {
            .docLineComment(comment)
        } else if comment.hasPrefix("//") {
            .lineComment(comment)
        } else if comment.hasPrefix("/**") {
            .docBlockComment(comment)
        } else {
            .blockComment(comment)
        }
    }
}

/// `comment-commands.json`: comments and the 3.8 command each parses to, nil for none.
private struct CommentCommandContract: Decodable {
    let commands: [CommentCommandContractEntry]
}

private struct CommentCommandContractEntry: Decodable {
    let comment: String
    let parsed: String?
}
