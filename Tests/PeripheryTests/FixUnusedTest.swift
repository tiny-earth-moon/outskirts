import Configuration
@testable import Fix
import Foundation
@testable import PeripheryKit
import SourceGraph
import SystemPackage
@testable import TestShared
import XCTest

/// `fix --rule unused` on indexed fixtures: what each eligibility rule removes or keeps, and the edits it makes.
final class FixUnusedTest: FixtureSourceGraphTestCase {
    // MARK: - Eligible kinds

    func testRemovesAFreeFunction() throws {
        let outcome = try removeUnused()

        XCTAssertEqual(outcome.decisions, ["4 fixUnusedFreeFunction()": "removed"])
        XCTAssertEqual(outcome.fixed, "public func fixUnusedKeptFunction() {}\n")
    }

    func testRemovesAMethodASubscriptAndAComputedProperty() throws {
        let outcome = try removeUnused()

        XCTAssertEqual(outcome.decisions, ["4 unusedMethod()": "removed", "6 subscript(_:)": "removed", "10 unusedComputed": "removed"])
        XCTAssertEqual(outcome.fixed, "public final class FixUnusedMemberHolder {\n    public init() {}\n\n}\n")
    }

    func testRemovesStoredPropertiesWithoutOrWithALiteralInitializer() throws {
        let outcome = try removeUnused()

        XCTAssertEqual(outcome.decisions, ["4 unusedLiteral": "removed", "5 unusedOptional": "removed", "6 unusedArray": "removed"])
        XCTAssertEqual(outcome.fixed, "public final class FixUnusedStoredHolder {\n    public init() {}\n\n}\n")
    }

    func testRemovesATypeATypealiasAndAnAssociatedType() throws {
        let outcome = try removeUnused()

        XCTAssertEqual(outcome.decisions, ["1 FixUnusedType": "removed", "5 FixUnusedAlias": "removed", "8 Unused": "removed"])
        XCTAssertFalse(outcome.fixed.contains("FixUnusedType"), outcome.fixed)
        XCTAssertFalse(outcome.fixed.contains("FixUnusedAlias"), outcome.fixed)
        XCTAssertFalse(outcome.fixed.contains("associatedtype"), outcome.fixed)
    }

    func testRemovesAnEnumCase() throws {
        let outcome = try removeUnused()

        XCTAssertEqual(outcome.decisions, ["3 unusedCase": "removed"])
        XCTAssertTrue(outcome.fixed.hasPrefix("enum FixUnusedEnum {\n    case used\n}\n"), outcome.fixed)
    }

    func testRemovesTheExtensionsOfARemovedType() throws {
        let outcome = try removeUnused()

        XCTAssertEqual(outcome.fixed, "public func fixUnusedExtendedKept() {}\n")
        XCTAssertEqual(outcome.decisions, ["1 FixUnusedExtended": "removed", "extension FixUnusedExtended": "removed", "extension Nested": "removed"])
        XCTAssertEqual(outcome.plan.changes.count, 1)
    }

    func testKeepsATypeWhoseExtensionIsNotInTheResults() throws {
        let outcome = try removeUnused(fixture: "testRemovesTheExtensionsOfARemovedType") { result in
            !(result.resultDeclaration.kind.isExtensionKind && result.resultDeclaration.name == "FixUnusedExtended")
        }

        XCTAssertEqual(outcome.decisions, ["1 FixUnusedExtended": "an extension of the type is kept", "extension Nested": "the extended type is kept"])
        XCTAssertTrue(outcome.fixed.hasPrefix("struct FixUnusedExtended {\n    struct Nested {}\n}\n"), outcome.fixed)
    }

    // MARK: - Exclusions

    func testKeepsTheImplementationOfARequirementThatIsKept() throws {
        let outcome = try removeUnused()

        XCTAssertEqual(outcome.decisions, ["6 paired()": "referenced by code that is kept"])
        XCTAssertEqual(outcome.fixed, outcome.original)
    }

    func testKeepsOverridesAndDynamicDeclarations() throws {
        let outcome = try removeUnused()

        XCTAssertEqual(outcome.decisions, [
            "4 overridden()": "overridden by kept code, or implements a kept requirement",
            "8 overridden()": "'override' declaration",
            "10 unusedDynamic()": "'dynamic' declaration",
            "15 fixUnusedHelperOfDynamic()": "referenced by code that is kept",
        ])
        XCTAssertEqual(outcome.fixed, outcome.original)
    }

    func testKeepsObjcDeclarations() throws {
        #if !canImport(ObjectiveC)
            throw XCTSkip("@objc needs the Objective-C runtime")
        #endif
        let outcome = try removeUnused()

        XCTAssertEqual(outcome.decisions, ["5 unusedObjc()": "'@objc' declaration"])
        XCTAssertEqual(outcome.fixed, outcome.original)
    }

    func testKeepsATypeWithAnIgnoredMember() throws {
        let outcome = try removeUnused()

        XCTAssertNotEqual(outcome.decisions["1 FixUnusedIgnoredHolder"], "removed")
        XCTAssertEqual(outcome.fixed, outcome.original)
    }

    func testKeepsDeclarationsWithARetainedAttribute() throws {
        let outcome = try removeUnused(retainAttributes: ["discardableResult"])

        XCTAssertEqual(outcome.decisions, [:])
        XCTAssertEqual(outcome.fixed, outcome.original)
    }

    func testKeepsAProtocolRequirementImplementedByKeptCode() throws {
        let outcome = try removeUnused()

        XCTAssertEqual(outcome.decisions, [:])
        XCTAssertEqual(outcome.fixed, outcome.original)
    }

    func testKeepsCasesOfCaseIterableAndCodableEnums() throws {
        let outcome = try removeUnused()

        // The case of the Codable enum is retained by the scan itself.
        XCTAssertEqual(outcome.decisions, ["3 iterableUnused": "case of a CaseIterable enum"])
        XCTAssertEqual(outcome.fixed, outcome.original)
    }

    func testKeepsCasesWhoseRemovalShiftsRawValues() throws {
        let outcome = try removeUnused()

        XCTAssertNotEqual(outcome.decisions["3 rawUnused"], "removed")
        XCTAssertEqual(outcome.fixed, outcome.original)
    }

    func testKeepsStoredPropertiesWithInitializersOrWrappers() throws {
        let outcome = try removeUnused()

        XCTAssertEqual(outcome.decisions, [
            "10 fixUnusedMakeValue()": "referenced by code that is kept",
            "17 computedInitializer": "stored property with a non-literal initializer",
            "18 staticLiteral": "static stored property with an initializer",
            "19 wrapped": "stored property with an attribute or property wrapper",
        ])
        XCTAssertEqual(outcome.fixed, outcome.original)
    }

    func testKeepsStoredPropertiesOfAStructWithAUsedMemberwiseInitializer() throws {
        let outcome = try removeUnused()

        XCTAssertEqual(outcome.decisions, ["3 unusedConstant": "the memberwise initializer of the struct is used"])
        XCTAssertEqual(outcome.fixed, outcome.original)
    }

    func testKeepsStoredPropertiesOfAnEquatableType() throws {
        let outcome = try removeUnused()

        XCTAssertEqual(outcome.decisions, ["4 unusedCompared": SkipReason.synthesizedConformance.description])
        XCTAssertEqual(outcome.fixed, outcome.original)
    }

    func testKeepsTheDeclarationsOfAModuleTheProjectDoesNotDeclare() throws {
        let dependency = try removeUnused(fixture: "testRemovesAFreeFunction", ownModules: ["App"])
        XCTAssertEqual(dependency.decisions, ["4 fixUnusedFreeFunction()": SkipReason.dependencyPackage.description])

        let own = try removeUnused(fixture: "testRemovesAFreeFunction", ownModules: ["FixUnusedFixtures"])
        XCTAssertEqual(own.decisions, ["4 fixUnusedFreeFunction()": "removed"])
    }

    func testKeepsWhatUncoveredClausesReachWithoutNamingIt() throws {
        let outcome = try removeUnused(readsConditionalClauses: true)

        XCTAssertEqual(outcome.decisions, [
            // Overridden in the clause.
            "3 fixUnusedHook()": SkipReason.uncoveredConditionalName.description,
            // Extended in the clause.
            "6 FixUnusedOnlyExtendedInRelease": SkipReason.uncoveredConditionalName.description,
            // A conformance added in the clause uses it.
            "9 description": SkipReason.uncoveredConditionalType.description,
            // The clause may call it as `grid[1]`.
            "13 subscript(_:)": SkipReason.implicitMemberWithUncoveredCode.description,
            "16 fixUnusedNotReached()": "removed",
        ])
    }

    func testKeepsNamesWrittenInUncoveredConditionalClauses() throws {
        let outcome = try removeUnused(readsConditionalClauses: true)

        XCTAssertEqual(outcome.decisions, [
            "1 fixUnusedReleaseOnly()": SkipReason.uncoveredConditionalName.description,
            "3 fixUnusedFlagOnly()": SkipReason.uncoveredConditionalName.description,
            "5 fixUnusedNotConditional()": "removed",
        ])
    }

    func testCollectsTheNamesOfEveryClauseNoBuildCompiled() {
        let source = """
        #if os(macOS)
            onMac()
        #elseif os(Linux)
            onLinux()
        #endif
        #if swift(>=5.9)
            newSwift()
        #else
            oldSwift()
        #endif
        #if canImport(UIKit)
            withUIKit()
        #endif
        #if !DEBUG
            let value = 1 <+> 2
        #endif
        """
        let macOS: Set = [IndexVariant(triple: "arm64-apple-macosx15.0", isOptimized: false)]

        let read = UncoveredConditionalNames.read(source, variants: macOS)
        XCTAssertEqual(read.names, ["onLinux", "newSwift", "oldSwift", "withUIKit", "value", "<+>"])
        XCTAssertEqual(read.typeNames, [])
        XCTAssertTrue(read.hasCode)
        // Without the triples of the file's builds, no clause is known to be compiled.
        XCTAssertTrue(UncoveredConditionalNames.read(source, variants: []).names.contains("onMac"))
    }

    func testCollectsTheTypesAClauseDeclaresExtendsOrInheritsFrom() {
        let source = """
        #if os(macOS)
            let compiled = 1
        #endif
        #if FLAG
            final class Sub: Base, Proto {
                @Wrapper var wrapped = 0
                func generic<T: Constraint>(_: T) where T: Other {}
            }
            extension Outer.Inner {}
        #endif
        """
        let read = UncoveredConditionalNames.read(source, variants: [IndexVariant(triple: "arm64-apple-macosx15.0", isOptimized: false)])

        XCTAssertEqual(read.typeNames, ["Sub", "Base", "Proto", "Wrapper", "T", "Constraint", "Other", "Outer", "Inner"])
        XCTAssertTrue(read.names.isSuperset(of: ["Sub", "wrapped", "generic", "Inner"]), "\(read.names)")
        XCTAssertFalse(read.names.contains("compiled"))
        XCTAssertFalse(UncoveredConditionalNames.read("#if os(macOS)\n    let compiled = 1\n#endif\n", variants: [IndexVariant(triple: "arm64-apple-macosx15.0", isOptimized: false)]).hasCode)
    }

    func testKeepsPublicDeclarationsUnlessIncluded() throws {
        let kept = try removeUnused(scanRetainsPublic: false)
        XCTAssertEqual(kept.decisions["1 fixUnusedPublicFunction()"], SkipReason.publicDeclaration.description)
        XCTAssertEqual(kept.decisions["7 fixUnusedInternalFunction()"], "removed")
        XCTAssertFalse(kept.decisions.contains { $0.key.contains("FixUnusedPublicMode") || $0.key.contains("fixUnusedPublicCase") ? $0.value == "removed" : false }, "\(kept.decisions)")

        let included = try removeUnused(scanRetainsPublic: false, includesPublic: true)
        XCTAssertEqual(included.decisions["1 fixUnusedPublicFunction()"], "removed")

        let retained = try removeUnused(scanRetainsPublic: false, fixRetainsPublic: true, includesPublic: true)
        XCTAssertEqual(retained.decisions["1 fixUnusedPublicFunction()"], SkipReason.publicDeclaration.description)
    }

    func testLocationOverrideIsKeptBeforePlanning() throws {
        let outcome = try removeUnused(fixture: "testRemovesAFreeFunction")
        let target = try XCTUnwrap(outcome.plan.applied.first)
        let overridden = FixTarget(
            rule: .unused, name: target.name, kind: target.kind, file: target.file, line: target.line,
            column: target.column, hasLocationOverride: true, id: target.id
        )

        let plan = makePlanner().plan([overridden])
        XCTAssertEqual(plan.skipped.map(\.reason), [.locationOverride])
        XCTAssertTrue(plan.changes.isEmpty)
    }

    func testSummaryListsEachRemovalWithItsOutputV2Id() throws {
        let outcome = try removeUnused(fixture: "testRemovesAFreeFunction")
        let id = try XCTUnwrap(outcome.plan.applied.first?.id)
        let summary = outcome.plan.summary(relativeTo: testFixturePath.removingLastComponent(), applying: false)

        XCTAssertTrue(id.hasPrefix("p2_"), id)
        XCTAssertTrue(summary.contains("  unused: 1\n"), summary)
        XCTAssertTrue(summary.contains("  would remove unused 'fixUnusedFreeFunction()' at testRemovesAFreeFunction.swift:4:6 [\(id)]"), summary)
    }

    // MARK: - Private

    private struct Outcome {
        let plan: FixPlan
        let original: String
        let fixed: String
        /// By line and name ("extension" and name for an extension), "removed" or the reason the declaration is kept.
        let decisions: [String: String]
    }

    private func makePlanner() -> FixPlanner {
        FixPlanner(workingTree: .ignored, indexDates: nil) { _ in false }
    }

    /// Plans the removals without writing: the fixture files are shared by the suite.
    /// - Parameter scanRetainsPublic: whether the scan retains the public declarations, so that they are not reported.
    /// - Parameter fixRetainsPublic: whether the configuration of the fix retains them.
    private func removeUnused(
        fixture: String? = nil,
        retainAttributes: [String] = [],
        scanRetainsPublic: Bool = true,
        fixRetainsPublic: Bool = false,
        includesPublic: Bool = false,
        ownModules: Set<String>? = nil,
        readsConditionalClauses: Bool = false,
        including isIncluded: (ScanResult) -> Bool = { _ in true }
    ) throws -> Outcome {
        let fixtureTests = fixture.map { [$0] }
        let results = analyze(retainPublic: scanRetainsPublic, retainAttributes: retainAttributes, fixtureTests: fixtureTests) {}
        let path = fixture.map { testFixturePath.removingLastComponent().appending("\($0).swift") } ?? testFixturePath

        let configuration = Configuration()
        configuration.retainAttributes = retainAttributes
        configuration.retainPublic = fixRetainsPublic
        var removal = try UnusedRemovalSet(
            results: results.filter(isIncluded),
            graph: Self.graph,
            configuration: configuration,
            uncoveredNames: readsConditionalClauses ? UncoveredConditionalNames(graph: Self.graph) : UncoveredConditionalNames(names: []),
            includesPublic: includesPublic,
            ownModules: ownModules
        )
        let plan = makePlanner().plan([], removing: &removal)

        var decisions: [String: String] = [:]
        func key(_ target: FixTarget) -> String {
            target.kind.isExtensionKind ? "extension \(target.name)" : "\(target.line) \(target.name)"
        }
        for target in plan.applied where target.file == path {
            decisions[key(target)] = "removed"
        }
        for skip in plan.skipped where skip.target.file == path {
            decisions[key(skip.target)] = skip.reason.description
        }

        let original = try String(contentsOfFile: path.string, encoding: .utf8)
        let fixed = plan.changes.first { $0.path == path }.flatMap { String(bytes: $0.fixed, encoding: .utf8) } ?? original
        return Outcome(plan: plan, original: original, fixed: fixed, decisions: decisions)
    }
}
