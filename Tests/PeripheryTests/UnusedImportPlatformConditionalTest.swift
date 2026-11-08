import Configuration
import SystemPackage
@testable import TestShared
import XCTest

/// Imports of modules used only inside a platform conditional `#if` block of a platform that was not built.
final class UnusedImportPlatformConditionalTest: SPMSourceGraphTestCase {
    private static let fixtureDirectory = FixturesProjectPath.appending("Sources/UnusedImportPlatformFixtures")

    override static func setUp() {
        super.setUp()

        build(projectPath: FixturesProjectPath)
    }

    func testImportUsedOnlyInPlatformConditionalIsNotReported() {
        indexFixtures()

        XCTAssertEqual(unusedImportedModules(inFileNamed: "PlatformOnlyUse.swift"), [])
    }

    func testImportNamedOnlyInPlatformConditionalIsNotReported() {
        indexFixtures()

        XCTAssertEqual(unusedImportedModules(inFileNamed: "PlatformOnlyModuleQualifiedUse.swift"), [])
    }

    func testImportIsReportedWhenPlatformConditionalUsesNothingFromTheModule() {
        indexFixtures()

        XCTAssertEqual(
            unusedImportedModules(inFileNamed: "PlatformBlockWithoutModuleUse.swift"),
            ["UnusedImportPlatformSupportFixtures"]
        )
    }

    func testImportIsReportedWhenPlatformConditionalRetentionIsDisabled() {
        let configuration = Configuration()
        configuration.disablePlatformConditionalRetention = true
        indexFixtures(configuration: configuration)

        XCTAssertEqual(
            unusedImportedModules(inFileNamed: "PlatformOnlyUse.swift"),
            ["UnusedImportPlatformSupportFixtures"]
        )
    }

    func testSystemImportIsKeptWhenPlatformConditionalNamesAnUnresolvedDeclaration() {
        let configuration = Configuration()
        configuration.enableUnusedSystemImports = true
        indexFixtures(configuration: configuration)

        XCTAssertEqual(unusedImportedModules(inFileNamed: "PlatformSystemUse.swift"), [])
    }

    func testSystemImportIsReportedWhenPlatformConditionalNamesOnlyScannedDeclarations() {
        let configuration = Configuration()
        configuration.enableUnusedSystemImports = true
        indexFixtures(configuration: configuration)

        XCTAssertEqual(unusedImportedModules(inFileNamed: "PlatformBlockWithoutSystemUse.swift"), ["Foundation"])
    }

    /// The index store only holds the clause of a `DEBUG` or custom flag block that the indexed build compiled.
    func testImportUsedOnlyInClauseOfNonPlatformConditionalIsNotReported() {
        indexFixtures()

        XCTAssertEqual(unusedImportedModules(inFileNamed: "ReleaseOnlyUse.swift"), [])
    }

    func testImportIsReportedWhenNonPlatformConditionalUsesNothingFromTheModule() {
        indexFixtures()

        XCTAssertEqual(
            unusedImportedModules(inFileNamed: "DebugBlockWithoutModuleUse.swift"),
            ["UnusedImportPlatformSupportFixtures"]
        )
    }

    /// The names of the compiled clause of a non-platform block are in the index store: they leave the system imports
    /// analysed.
    func testSystemImportIsReportedWhenCompiledNonPlatformClauseNamesOnlyIndexedDeclarations() {
        let configuration = Configuration()
        configuration.enableUnusedSystemImports = true
        indexFixtures(configuration: configuration)

        XCTAssertEqual(unusedImportedModules(inFileNamed: "CompiledDebugBlockWithoutSystemUse.swift"), ["Foundation"])
    }

    // MARK: - Private

    private func indexFixtures(configuration: Configuration = Configuration()) {
        let files = [
            "Support/PlatformSupport.swift",
            "Client/PlatformOnlyUse.swift",
            "Client/PlatformOnlyModuleQualifiedUse.swift",
            "Client/PlatformBlockWithoutModuleUse.swift",
            "Client/ReleaseOnlyUse.swift",
            "Client/DebugBlockWithoutModuleUse.swift",
            "System/PlatformSystemUse.swift",
            "System/PlatformBlockWithoutSystemUse.swift",
            "System/CompiledDebugBlockWithoutSystemUse.swift",
        ]
        index(sourceFiles: files.map { Self.fixtureDirectory.appending($0) }, configuration: configuration)
    }
}
