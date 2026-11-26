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

    func testPublicMembersOfNestedImportedInternalType() {
        index()

        assertNotRedundantPublicAccessibility(.functionMethodStatic("makeNestedInner()"))
    }

    func testPublicMembersOfInternalTypeExtendedInTwoModules() {
        index()

        assertRedundantPublicAccessibility(.functionMethodStatic("makeSharedFromHelpers()"))
        assertNotRedundantPublicAccessibility(.functionMethodStatic("makeSharedFromHelpers2()"))
    }

    func testPublicWitnessOfConformanceToImportedInternalProtocol() {
        index()

        assertNotRedundantPublicAccessibility(.functionMethodInstance("describeImported()"))
    }

    func testPublicMemberReferencedThroughTestableImportOfIntermediateModule() {
        index()

        assertNotRedundantPublicAccessibility(.varInstance("chainLabel"))
    }

    func testPublicMemberOfSameModuleExtensionWitnessingConformanceInAnotherModule() {
        index()

        assertRedundantPublicAccessibility(.varInstance("description", line: 4))
    }
}
