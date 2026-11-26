import Configuration
@testable import TestShared
import XCTest

final class MultiModuleAccessibilityTest: SPMSourceGraphTestCase {
    override static func setUp() {
        super.setUp()
        build(projectPath: FixturesProjectPath.appending("MultiModuleAccessibility"))
    }

    func testTestableImportOfFacadeDoesNotCoverReexportedModule() {
        index()

        assertNotRedundantPublicAccessibility(.functionFree("exportedThroughFacade()"))
        assertRedundantPublicAccessibility(.functionFree("facadeTestableHelper()"))
    }

    /// The `package` access level is not modelled: a public declaration used by another module of the same package
    /// needs its accessibility, as `internal` would not compile, and no narrower `package` level is suggested.
    func testPublicDeclarationUsedOnlyWithinPackage() {
        index()

        assertNotRedundantPublicAccessibility(.functionFree("packageWideHelper()"))
        assertNotRedundantPublicAccessibility(.struct("PackageScopedValue"))
    }

    /// Members of a `package` type default to `internal`: removing `public` from a member used by another module of
    /// the package does not compile.
    func testPublicMemberOfPackageTypeUsedByAnotherModule() {
        index()

        assertNotRedundantPublicAccessibility(.functionMethodInstance("publicMemberOfPackageType()"))
        assertRedundantPublicAccessibility(.functionMethodInstance("publicMemberOfPackageTypeUsedInModule()"))
    }

    /// The members of an extension of a `package` type, and of a `package` type nested in a public type, also default
    /// to `internal`.
    func testPublicMembersOfExtendedOrNestedPackageTypeUsedByAnotherModule() {
        index()

        assertNotRedundantPublicAccessibility(.functionMethodInstance("publicExtensionMemberOfPackageType()"))
        assertNotRedundantPublicAccessibility(.functionMethodInstance("publicMemberOfNestedPackageType()"))
    }

    func testPackageMembersOfPublicType() {
        index(configuration: membersConfiguration())

        assertNotRedundantPublicAccessibility(.struct("PackageScopedValue")) {
            self.assertNotRedundantPublicAccessibility(.varInstance("packageToken"))
            self.assertNotRedundantPublicAccessibility(.functionConstructor("init(packageToken:)"))
            self.assertNotRedundantPublicAccessibility(.functionMethodInstance("packageDescription()"))
        }
    }

    func testSPIDeclarationUsedThroughSPIImport() {
        index()

        assertNotRedundantPublicAccessibility(.functionFree("spiOnlyEntry()"))
    }

    func testProtocolExtensionWitnessOfConformanceInAnotherModule() {
        index()

        assertNotRedundantPublicAccessibility(.functionMethodInstance("greetingText()"))
        assertNotRedundantPublicAccessibility(.functionMethodInstance("farewellText()"))
    }

    func testProtocolExtensionWitnessOfConformanceInAnotherModuleWithPublicMembers() {
        index(configuration: membersConfiguration())

        assertNotRedundantPublicAccessibility(.functionMethodInstance("greetingText()"))
        assertNotRedundantPublicAccessibility(.functionMethodInstance("farewellText()"))
    }

    func testExtensionsOfInternalTypesWithoutRetainedModules() {
        index()

        assertRedundantPublicAccessibility(.functionMethodInstance("retainedModuleExtensionMember()"))
        assertRedundantPublicAccessibility(.functionMethodInstance("unretainedModuleExtensionMember()"))
    }

    func testRetainedModuleExtendingInternalTypeOfUnretainedModule() {
        index(configuration: retainingPublic(ofModules: ["LayerC"]))

        assertNotRedundantPublicAccessibility(.functionMethodInstance("retainedModuleExtensionMember()"))
        assertRedundantPublicAccessibility(.functionMethodInstance("unretainedModuleExtensionMember()"))
    }

    func testUnretainedModuleExtendingInternalTypeOfRetainedModule() {
        index(configuration: retainingPublic(ofModules: ["LayerA"]))

        assertRedundantPublicAccessibility(.functionMethodInstance("unretainedModuleExtensionMember()"))
        assertRedundantPublicAccessibility(.functionMethodInstance("retainedModuleExtensionMember()"))
    }

    // MARK: - Private

    private func membersConfiguration() -> Configuration {
        let configuration = Configuration()
        configuration.enableRedundantPublicMembers = true
        return configuration
    }

    private func retainingPublic(ofModules modules: [String]) -> Configuration {
        let configuration = Configuration()
        configuration.retainPublicModules = modules
        return configuration
    }
}
