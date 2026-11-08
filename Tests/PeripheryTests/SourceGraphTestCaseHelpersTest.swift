#if os(macOS)
    import Configuration
    @testable import SourceGraph
    @testable import TestShared
    import XCTest

    /// Proves the assertion helpers fail when their premise does not hold.
    final class SourceGraphTestCaseHelpersTest: SPMSourceGraphTestCase {
        override static func setUp() {
            super.setUp()

            build(projectPath: FixturesProjectPath)
            index(configuration: Configuration())
        }

        func testAssertReferencedModule_failsForAnUnknownModule() {
            XCTExpectFailure("The module is imported nowhere.")
            assertReferenced(.module("NoSuchModuleImportedAnywhere"))
        }

        func testAssertReferencedModule_failsWhenTheScopedModuleDoesNotImportIt() {
            XCTExpectFailure("UnusedImportFixtureA does not import UnusedImportFixtureB.")
            module("UnusedImportFixtureA") {
                self.assertReferenced(.module("UnusedImportFixtureB"))
            }
        }

        func testAssertReferenced_failsForAnAmbiguousDescription() throws {
            let groups = Dictionary(grouping: Self.graph.rootDeclarations) { "\($0.kind.rawValue) \($0.name ?? "")" }
            let duplicate = try XCTUnwrap(groups.values.first { $0.count > 1 && $0.first?.name != nil }?.first)
            let description = DeclarationDescription(kind: duplicate.kind, name: try XCTUnwrap(duplicate.name), line: nil)

            XCTExpectFailure("Several declarations match \(description).")
            assertReferenced(description)
        }
    }
#endif
