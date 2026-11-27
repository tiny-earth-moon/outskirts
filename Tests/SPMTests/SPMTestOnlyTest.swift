import Configuration
@testable import PeripheryKit
import SourceGraph
@testable import TestShared
import XCTest

/// `report_test_only` on a package whose executable target `App` is tested by `AppTests`.
final class SPMTestOnlyTest: SPMSourceGraphTestCase {
    override static func setUp() {
        super.setUp()
        build(projectPath: FixturesProjectPath.appending("TestOnlyProject"))
    }

    private func scan(reportTestOnly: Bool, explain: [String] = [], platformConditionalRetention: Bool = false) {
        let configuration = Configuration()
        configuration.apply(\.$reportTestOnly, reportTestOnly)
        configuration.apply(\.$disablePlatformConditionalRetention, !platformConditionalRetention)
        configuration.explain = explain
        index(configuration: configuration)
    }

    private var testOnlyResults: [ScanResult] {
        Self.results.filter { result in
            if case .testOnly = result.annotation {
                return true
            }
            return false
        }
    }

    /// The test-only results as `Parent.name`, or `name` for a top-level declaration.
    private func qualifiedNames(of results: [ScanResult]) -> [String] {
        results.map { result in
            [result.declaration.parent?.name, result.declaration.name].compactMap(\.self).joined(separator: ".")
        }.sorted()
    }

    private var testOnlyNames: [String] {
        Self.results.compactMap { result in
            if case .testOnly = result.annotation {
                return result.declaration.name
            }
            return nil
        }.sorted()
    }

    /// The results other than `testOnly`, as kind, name and location.
    private var otherResults: [String] {
        Self.results.compactMap { result in
            if case .testOnly = result.annotation {
                return nil
            }
            return "\(result.annotation.name) \(result.declaration.name) \(result.declaration.location)"
        }.sorted()
    }

    /// The results located in `Sources/App/Probe.swift`, as kind and `Parent.name` or `name`.
    private var probeResults: [String] {
        Self.results.filter { $0.declaration.location.file.path.string.hasSuffix("Sources/App/Probe.swift") }.map { result in
            let name = [result.declaration.parent?.name, result.declaration.name].compactMap(\.self).joined(separator: ".")
            return "\(result.annotation.name) \(name)"
        }.sorted()
    }

    private func probeDeclaration(named name: String) throws -> Declaration {
        try XCTUnwrap(indexedDeclaration(named: name, inFileEndingWith: "Sources/App/Probe.swift"))
    }

    /// The results located in test files, as kind, name and location.
    private var testFileResults: [String] {
        Self.results.filter(\.declaration.location.file.isTestFile).map { result in
            "\(result.annotation.name) \(result.declaration.name) \(result.declaration.location)"
        }.sorted()
    }

    func testDeclarationsUsedOnlyByTests_areTestOnly() {
        scan(reportTestOnly: true)

        XCTAssertEqual(testOnlyNames, ["ChainEntry", "LegacyExporter", "PairingCatalog", "PlatformProbe", "SnapshotOnlyView", "describeForTests()", "resetForPlatform()", "usedOnlyByTests()"])
        assertReferenced(.struct("SnapshotOnlyView"))
    }

    func testDeclarationsOfTheTestTarget_keepTheResultsTheyHadWithoutTheOption() throws {
        scan(reportTestOnly: false)
        let resultsWithout = testFileResults

        scan(reportTestOnly: true)

        XCTAssertEqual(testFileResults, resultsWithout)
        XCTAssertFalse(testFileResults.contains { $0.hasPrefix("testOnly ") })
        assertReferenced(.enum("TestFixtures"))
        let helper = try XCTUnwrap(indexedDeclaration(named: "prepareForTest()"))
        XCTAssertTrue(helper.declaration.location.file.isTestFile)
        XCTAssertTrue(helper.isUsed)
    }

    func testDeclarationsUsedByTheApp_areNotTestOnly() {
        scan(reportTestOnly: true)

        let testOnly = Set(testOnlyNames)
        for name in ["AppScreen", "show()", "SharedFormatter", "format()", "Settings", "usedByApp()", "render()"] {
            XCTAssertFalse(testOnly.contains(name), name)
        }
    }

    func testDeclarationCalledInAnUncompiledBranchOfTheApp_isNotTestOnly() {
        scan(reportTestOnly: true)

        XCTAssertFalse(testOnlyNames.contains("flushOnRelease()"))
        XCTAssertFalse(testOnlyNames.contains("CrashReporter"))
    }

    func testInitializerCalledThroughItsTypeInAnUncompiledBranchOfTheApp_isNotTestOnly() {
        scan(reportTestOnly: true)

        XCTAssertFalse(testOnlyNames.contains("init(endpoint:transport:)"))
        XCTAssertFalse(testOnlyEntries.keys.contains { $0.name == "init(endpoint:transport:)" })
        XCTAssertFalse(testOnlyNames.contains("EventsClient"))
    }

    func testDeclarationReadInAnUncompiledBranchOfAStaticInitializerClosure_isNotTestOnly() {
        scan(reportTestOnly: true)

        for name in ["secondary", "PaletteSource", "colors", "Palette", "cachedColors", "Theme"] {
            XCTAssertFalse(testOnlyNames.contains(name), name)
        }
    }

    func testChainOfTestOnlyDeclarations_isReportedOnItsEntryOnly() {
        scan(reportTestOnly: true)

        let reported = Set(testOnlyNames)
        XCTAssertTrue(reported.contains("ChainEntry"))
        for name in ["start()", "ChainMiddle", "step()", "ChainLeaf", "finish()"] {
            XCTAssertFalse(reported.contains(name), name)
        }
        let leaf = testOnlyEntries.first { $0.key.name == "ChainLeaf" }
        XCTAssertEqual(leaf?.value.name, "ChainEntry")
    }

    func testTypesReachedOnlyThroughTheMemberwiseInitializerOfATestOnlyType_areLinksOfItsChain() {
        scan(reportTestOnly: true)

        let reported = Set(testOnlyNames)
        XCTAssertTrue(reported.contains("PairingCatalog"))
        for name in ["all", "ColorPairing", "tokens", "ContrastLevel", "minimum", "Backdrop", "shades"] {
            XCTAssertFalse(reported.contains(name), name)
        }
        let level = testOnlyEntries.first { $0.key.name == "ContrastLevel" }
        XCTAssertEqual(level?.value.name, "PairingCatalog")
    }

    func testMembersReachedOnlyThroughTheMemberwiseInitializerOfAnUnusedType_areNotTestOnly() {
        scan(reportTestOnly: true)

        XCTAssertFalse(testOnlyEntries.keys.contains { ["UnusedRecord", "stamp", "RecordStamp"].contains($0.name) })
    }

    func testWitnessOfATestOnlyRequirement_isReportedOnTheRequirement() {
        scan(reportTestOnly: true)

        XCTAssertEqual(
            qualifiedNames(of: testOnlyResults).filter { $0.hasSuffix("describeForTests()") },
            ["Describing.describeForTests()"]
        )
        let witness = testOnlyEntries.first { $0.key.name == "describeForTests()" && $0.key.parent?.name == "Report" }
        XCTAssertEqual(witness?.value.parent?.name, "Describing")
    }

    func testExcludedEntry_hidesItsChain() throws {
        scan(reportTestOnly: true)
        let configuration = Configuration()
        configuration.apply(\.$reportExclude, [.pattern("**/ExcludedEntry.swift")])

        let filtered = try OutputDeclarationFilter(configuration: configuration, logger: Self.logger).filter(testOnlyResults, with: nil)

        let names = Set(qualifiedNames(of: filtered))
        for name in ["LegacyExporter", "LegacyExporter.export()", "LegacyEncoder", "LegacyEncoder.encode()"] {
            XCTAssertFalse(names.contains(name), name)
        }
        XCTAssertTrue(names.contains("ChainEntry"))
    }

    func testExplanationOfAChainLink_namesItsReportedEntry() {
        scan(reportTestOnly: true, explain: ["ChainLeaf", "ChainEntry"])

        let leaf = explanation(of: "ChainLeaf")
        XCTAssertTrue(leaf.contains("is test-only, reported on the entry of its chain, ChainEntry (struct at "), leaf)
        XCTAssertTrue(leaf.contains("only code in test files uses it, through the reference chain:"), leaf)
        XCTAssertTrue(leaf.contains("ChainMiddle.step() (function at "), leaf)

        let entry = explanation(of: "ChainEntry")
        XCTAssertTrue(entry.contains("ChainEntry (struct at "), entry)
        XCTAssertTrue(entry.contains(") is test-only: only code in test files uses it, through the reference chain:"), entry)
    }

    func testDeclarationNamedOnlyInAPlatformConditionalOfATestFile_isTestOnly() {
        scan(reportTestOnly: true, platformConditionalRetention: true)

        XCTAssertEqual(probeResults, ["testOnly DeviceGate.resetForPlatform()", "testOnly PlatformProbe"])
    }

    func testDeclarationNamedOnlyInAPlatformConditionalOfATestFile_explainsItsRetentionForTests() {
        scan(reportTestOnly: true, explain: ["PlatformProbe"], platformConditionalRetention: true)

        let probe = explanation(of: "PlatformProbe")
        XCTAssertFalse(probe.contains("reason not recorded"), probe)
        XCTAssertTrue(probe.contains(") is test-only: only code in test files uses it, through the reference chain:"), probe)
        XCTAssertTrue(probe.contains("PlatformConditionalRetainer, its name is written in a platform conditional `#if` block of "), probe)
        XCTAssertTrue(probe.contains("Tests/AppTests/AppTests.swift, only in test files, so the app does not use it through this retention"), probe)
    }

    func testDeclarationNamedInAPlatformConditionalOfTheAppToo_isNotTestOnly() throws {
        scan(reportTestOnly: true, platformConditionalRetention: true)

        XCTAssertFalse(probeResults.contains { $0.contains("SharedProbe") }, "\(probeResults)")
        let probe = try probeDeclaration(named: "SharedProbe")
        XCTAssertTrue(isRetained(probe))
        XCTAssertFalse(retainedForTestsOnly.contains(probe))
    }

    func testDeclarationNamedOnlyInAPlatformConditionalOfATestFile_withoutTheOption_isRetained() throws {
        scan(reportTestOnly: false, platformConditionalRetention: true)

        XCTAssertEqual(probeResults, [])
        XCTAssertTrue(retainedForTestsOnly.isEmpty)
        XCTAssertTrue(try isRetained(probeDeclaration(named: "PlatformProbe")))
        XCTAssertTrue(try isRetained(probeDeclaration(named: "resetForPlatform()")))
    }

    func testWithoutTheOption_nothingIsTestOnlyAndTheOtherResultsAreUnchanged() {
        scan(reportTestOnly: false)
        let resultsWithout = otherResults

        XCTAssertTrue(testOnlyNames.isEmpty)
        XCTAssertTrue(markedTestOnlyDeclarations.isEmpty)
        assertReferenced(.struct("SnapshotOnlyView"))

        scan(reportTestOnly: true)

        XCTAssertEqual(otherResults, resultsWithout)
    }
}
