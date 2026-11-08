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
    }
#endif
