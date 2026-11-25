@testable import TestShared
import XCTest

final class ImportedTypeExtensionAccessibilityTest: SPMSourceGraphTestCase {
    override static func setUp() {
        super.setUp()
        build(projectPath: FixturesProjectPath.appending("ImportedTypeExtension"))
    }

    func testPublicMembersOfImportedInternalType() {
        index()

        assertNotRedundantPublicAccessibility(.functionMethodStatic("makeImportedValue(style:)"))
        assertRedundantPublicAccessibility(.functionMethodStatic("makeTestableValue()"))
        assertNotRedundantPublicAccessibility(.enum("Style"))
        assertNotRedundantPublicAccessibility(.varInstance("debugDescription"))
    }
}
