@testable import Indexer
@testable import SourceGraph
import SwiftParser
import SwiftSyntax
@testable import SyntaxAnalysis
import XCTest

final class PlatformConditionalNameCollectorTest: XCTestCase {
    private let macOS = PlatformBuildConfiguration(triple: "arm64-apple-macosx14.0")!
    private let iOSSimulator = PlatformBuildConfiguration(triple: "arm64-apple-ios18.0-simulator")!

    private func collect(_ source: String, _ configurations: [PlatformBuildConfiguration], narrowsNestedBlocks: Bool = false) -> Set<String> {
        PlatformConditionalNameCollector.collect(
            from: Parser.parse(source: source),
            configurations: configurations,
            narrowsNestedBlocks: narrowsNestedBlocks
        )
    }

    private func collectAll(_ source: String, _ configurations: [PlatformBuildConfiguration]) -> PlatformConditionalNames {
        PlatformConditionalNameCollector.collectAll(from: Parser.parse(source: source), configurations: configurations)
    }

    /// Monday's iOS unit of another target, left in a shared store, predates the call added on Tuesday under
    /// `#if os(iOS)`: only the macOS unit written by Tuesday's build narrows the clauses, so the call is collected.
    func testUnitOlderThanTheFile_doesNotNarrowItsClauses() {
        let macOSVariant = IndexVariant(triple: "arm64-apple-macosx14.0", isOptimized: false)
        let iOSVariant = IndexVariant(triple: "arm64-apple-ios18.0", isOptimized: false)
        let file = SourceFile(path: "/App/Shared.swift", modules: ["App_iOS", "App_macOS"], variants: [macOSVariant, iOSVariant], currentVariants: [macOSVariant])
        let source = """
        #if os(iOS)
            helper()
        #else
            onMac()
        #endif
        """

        let configurations = SwiftIndexer.platformBuildConfigurations(of: file)

        XCTAssertEqual(configurations, [macOS])
        XCTAssertEqual(collect(source, configurations), ["helper"])
        XCTAssertEqual(SwiftIndexer.platformBuildConfigurations(of: SourceFile(path: "/App/Shared.swift", modules: ["App"], variants: [iOSVariant], currentVariants: [])), [])
    }

    func testCollectsUsesThatWriteNoName() {
        let source = """
        #if os(iOS)
        let isEqual = lhs <~> rhs
        let negated = -value
        extension Module.FixtureType: @unchecked Sendable, FixtureProtocol & OtherProtocol {}
        final class FixtureSubclass: FixtureBase {
            override func update() {}
            override var size: Int { 0 }
            override subscript(index: Int) -> Int { index }
            func notOverridden() {}
        }
        #endif
        """

        let collected = collectAll(source, [macOS])

        XCTAssertEqual(collected.references, [
            "lhs", "<~>", "rhs", "-", "value", "Module", "unchecked", "Sendable", "FixtureProtocol", "OtherProtocol",
            "FixtureBase", "Int", "index",
        ])
        XCTAssertEqual(collected.conformances, [
            PlatformConditionalConformance(typeName: "FixtureType", protocolName: "Sendable"),
            PlatformConditionalConformance(typeName: "FixtureType", protocolName: "FixtureProtocol"),
            PlatformConditionalConformance(typeName: "FixtureType", protocolName: "OtherProtocol"),
        ])
        XCTAssertEqual(collected.inheritedNames, ["FixtureBase"])
        XCTAssertEqual(collected.overriddenNames, ["update", "size", "subscript"])
        XCTAssertEqual(collected.otherClauseNames, [])
        XCTAssertEqual(collected.operatorClauseNames, ["<~>": collected.references, "-": collected.references])
    }

    /// The names of the other `#if` blocks only account for imports: they are collected apart, both clauses whole.
    func testCollectsNamesOfNonPlatformConditionalsApart() {
        let source = """
        #if !DEBUG
        releaseOnly()
        #else
        debugOnly()
        #endif
        """

        var expected = PlatformConditionalNames()
        expected.otherClauseNames = ["releaseOnly", "debugOnly"]
        XCTAssertEqual(collectAll(source, [macOS]), expected)
    }

    func testParsesKnownTriples() throws {
        let catalyst = try XCTUnwrap(PlatformBuildConfiguration(triple: "x86_64-apple-ios17.0-macabi"))
        XCTAssertTrue(try catalyst.isActiveTargetOS(name: "iOS"))
        XCTAssertFalse(try catalyst.isActiveTargetOS(name: "macOS"))
        XCTAssertTrue(try catalyst.isActiveTargetEnvironment(name: "macCatalyst"))
        XCTAssertTrue(try catalyst.isActiveTargetArchitecture(name: "x86_64"))

        XCTAssertTrue(try macOS.isActiveTargetOS(name: "OSX"))
        XCTAssertFalse(try macOS.isActiveTargetEnvironment(name: "simulator"))
        XCTAssertTrue(try iOSSimulator.isActiveTargetEnvironment(name: "simulator"))

        let linux = try XCTUnwrap(PlatformBuildConfiguration(triple: "aarch64-unknown-linux-gnu"))
        XCTAssertTrue(try linux.isActiveTargetOS(name: "Linux"))
        XCTAssertTrue(try linux.isActiveTargetArchitecture(name: "arm64"))

        let visionOS = try XCTUnwrap(PlatformBuildConfiguration(triple: "arm64-apple-xros2.0-simulator"))
        XCTAssertTrue(try visionOS.isActiveTargetOS(name: "visionOS"))
    }

    func testRejectsTriplesWhoseConditionsAreUncertain() {
        for triple in [
            "",
            "arm64e-apple-ios18.0",
            "arm64_32-apple-watchos10.0",
            "aarch64-unknown-linux-android",
            "x86_64-unknown-windows-msvc",
            "arm64-apple-ios18.0-unknown",
            "wasm32-unknown-wasi",
        ] {
            XCTAssertNil(PlatformBuildConfiguration(triple: triple), triple)
        }
    }

    func testThrowsForQueriesATripleCannotAnswer() {
        XCTAssertThrowsError(try macOS.isCustomConditionSet(name: "DEBUG"))
        XCTAssertThrowsError(try macOS.isActiveTargetOS(name: "Fuchsia"))
        XCTAssertThrowsError(try macOS.isActiveTargetArchitecture(name: "mips"))
        XCTAssertThrowsError(try macOS.isActiveTargetEnvironment(name: "macabi"))
    }

    /// The unnamed uses of a clause are only collected when no configuration compiles it: not from the `#else` of a
    /// nested `#if os(Windows)`, nor from `canImport(Dispatch)` on macOS, nor without a configuration.
    func testCollectsUnnamedUsesOnlyFromClausesNoConfigurationCompiles() {
        let source = """
        #if !os(WASI)
        #if os(Windows)
        _ = WindowsHandle(descriptor: 0)
        #else
        _ = PosixHandle(descriptor: 0)
        _ = values[0]
        #endif
        #endif
        #if canImport(Dispatch)
        _ = DispatchBuffer(capacity: 0)
        #endif
        #if canImport(UIKit)
        _ = UIKitView(frame: 0)
        #endif
        #if canImport(SomeLibrary)
        _ = LibraryValue()
        #endif
        """

        let collected = collectAll(source, [macOS])

        XCTAssertEqual(collected.constructions, [
            PlatformConditionalConstruction(typeName: "WindowsHandle", labels: ["descriptor"]),
            PlatformConditionalConstruction(typeName: "UIKitView", labels: ["frame"]),
        ])
        XCTAssertEqual(collected.subscriptedNames, [])
        XCTAssertTrue(collected.references.isSuperset(of: ["PosixHandle", "LibraryValue"]))
        // `canImport(Dispatch)` is compiled on macOS: the index store holds its references.
        XCTAssertFalse(collected.references.contains("DispatchBuffer"))
        XCTAssertEqual(collectAll(source, []).constructions, [])
    }

    func testCollectsInitializerCallsThatWriteNoInitializerName() {
        let source = """
        #if os(iOS)
        let camera: Camera? = .init(fieldOfView: 1, 2)
        _ = Lens.init(radius:)
        _ = Module.Sensor<Int>(size: 1) { _ in }
        make(Filter.self)
        let value = Callable()
        value()
        _ = list[0]
        #endif
        """

        let collected = collectAll(source, [macOS])

        XCTAssertTrue(collected.constructions.isSuperset(of: [
            PlatformConditionalConstruction(typeName: "Camera", labels: ["fieldOfView", "_"]),
            PlatformConditionalConstruction(typeName: "Lens", labels: ["radius"]),
            PlatformConditionalConstruction(typeName: "Sensor", labels: ["size"]),
            PlatformConditionalConstruction(typeName: "Filter", labels: nil),
            PlatformConditionalConstruction(typeName: "Callable", labels: []),
        ]))
        XCTAssertTrue(collected.subscriptedNames.contains("list"))
        XCTAssertTrue(collected.valueCalledNames.contains("Callable"))
    }

    /// `--explain` cites the line of the call, not the first line that names the type.
    func testCollectsConstructionSitesForExplanations() {
        let source = """
        #if os(iOS)
        func render(context: Context) {}
        let renderer = Renderer(context: Context(device: device))
        #endif
        """
        let syntax = Parser.parse(source: source)
        let collector = PlatformConditionalNameCollector(
            configurations: [macOS],
            locationConverter: SourceLocationConverter(fileName: "Render.swift", tree: syntax)
        )
        collector.walk(syntax)

        let construction = PlatformConditionalConstruction(typeName: "Context", labels: ["device"])
        XCTAssertEqual(collector.constructionSites[construction]?.map(\.line), [3])
        XCTAssertEqual(collector.sites["Context"]?.map(\.line), [2, 3])
    }

    /// An operator applied in a clause a configuration compiles is resolved by the index store.
    func testCollectsOperatorClauseNamesOnlyFromClausesNotCertainlyCompiled() {
        let source = """
        #if canImport(Dispatch)
        let amount = Amount() * 2
        #if os(Windows)
        let length = Length() * 2
        #endif
        #endif
        """

        let collected = collectAll(source, [macOS])

        XCTAssertEqual(collected.operatorClauseNames["*"], ["Length", "*"])
        // The names of the clause macOS compiles are not collected either, those of the nested block are.
        XCTAssertTrue(collected.references.isSuperset(of: ["*", "Length"]))
        XCTAssertFalse(collected.references.contains("Amount"))
    }

    func testConstructionMatchesInitializersByLabels() {
        let call = PlatformConditionalConstruction(typeName: "T", labels: ["value", "_"])
        XCTAssertTrue(call.matches(initializerName: "init(value:_:)"))
        XCTAssertTrue(call.matches(initializerName: "init(value:_:scale:)"))
        XCTAssertTrue(call.matches(initializerName: "init(value:)"), "variadic")
        XCTAssertFalse(call.matches(initializerName: "init(label:_:)"))
        XCTAssertFalse(PlatformConditionalConstruction(typeName: "T", labels: ["_"]).matches(initializerName: "init()"))
        XCTAssertTrue(PlatformConditionalConstruction(typeName: "T", labels: nil).matches(initializerName: "init(a:)"))
        XCTAssertTrue(PlatformConditionalConstruction(typeName: "T", labels: []).matchesExactly(initializerName: "init()"))
        XCTAssertFalse(call.matchesExactly(initializerName: "init(value:_:scale:)"))
    }

    /// A `canImport()` of a system module the platform settles, or of a module of the project the build compiled, is
    /// evaluated: the clause the build compiled is in the index store, and its names are not collected.
    func testNamesOfCompiledCanImportClausesAreNotCollected() {
        let macOSVariant = IndexVariant(triple: "arm64-apple-macosx14.0", isOptimized: false)
        let file = SourceFile(path: "/App/Shared.swift", modules: ["App_macOS"], variants: [macOSVariant], currentVariants: [macOSVariant])
        let configurations = SwiftIndexer.platformBuildConfigurations(of: file, modulesByVariant: [macOSVariant: ["App_macOS"]])
        let source = """
        #if canImport(Foundation)
            withFoundation()
        #endif
        #if canImport(App_iOS) || canImport(App_macOS)
            inApp()
        #endif
        #if canImport(UIKit)
            withUIKit()
        #endif
        #if canImport(SomeLibrary)
            withLibrary()
        #endif
        """

        XCTAssertEqual(collect(source, configurations), ["withUIKit", "withLibrary"])
        XCTAssertEqual(collect(source, []), ["withFoundation", "inApp", "withUIKit", "withLibrary"])
    }

    /// A member written on a receiver records what the clause tells of its type; a type name, an implicit member and a
    /// bare name outside a type the clause declares stay unscoped.
    func testReadsTheReceiversOfMembers() {
        let source = """
        func entry() {
            #if os(iOS)
            let arguments = ProcessInfo.processInfo.arguments
            _ = arguments.indices.contains(1)
            let annotated: Model? = nil
            annotated?.load()
            Model.make().reset(.zero)
            free()
            #endif
        }
        #if os(iOS)
        extension Model {
            func run() { refresh() }
        }
        #endif
        """
        let collected = collectAll(source, [macOS])
        let receivers = Dictionary(collected.memberUses.map { ($0.name, $0.receiver) }, uniquingKeysWith: { first, _ in first })

        let processInfo = PlatformConditionalReceiver.member(.name("ProcessInfo"), "processInfo")
        XCTAssertEqual(receivers["contains"], .member(.inferred(.member(processInfo, "arguments")), "indices"))
        XCTAssertEqual(receivers["load"], .typeName("Model"))
        XCTAssertEqual(receivers["reset"], .call(.member(.name("Model"), "make"), hasOnlyLiteralArguments: true))
        XCTAssertEqual(receivers["refresh"], .enclosingTypes(["Model"]))
        XCTAssertTrue(collected.unscopedReferences.isSuperset(of: ["ProcessInfo", "Model", "zero", "free", "arguments"]))
        XCTAssertFalse(collected.unscopedReferences.contains("contains"))
    }

    func testAnswersCanImportOnlyForSettledSystemModules() throws {
        let answering = macOS.answeringCanImport
        XCTAssertTrue(try answering.canImport(importPath: [(.identifier("Dispatch"), "Dispatch")], version: .unversioned))
        XCTAssertFalse(try answering.canImport(importPath: [(.identifier("UIKit"), "UIKit")], version: .unversioned))
        XCTAssertThrowsError(try answering.canImport(importPath: [(.identifier("SomeLibrary"), "SomeLibrary")], version: .unversioned))
        XCTAssertThrowsError(try macOS.canImport(importPath: [(.identifier("Dispatch"), "Dispatch")], version: .unversioned))
    }

    func testCollectsOnlyClausesNoConfigurationCompiled() {
        let source = """
        #if os(iOS)
        iOSOnly()
        #elseif os(macOS) && !targetEnvironment(simulator)
        macOSOnly()
        #elseif (os(tvOS) || os(watchOS))
        tvOrWatchOnly()
        #else
        fallbackOnly()
        #endif
        """

        XCTAssertEqual(collect(source, [macOS]), ["iOSOnly", "tvOrWatchOnly", "fallbackOnly"])
        XCTAssertEqual(collect(source, [iOSSimulator]), ["macOSOnly", "tvOrWatchOnly", "fallbackOnly"])
        XCTAssertEqual(collect(source, [macOS, iOSSimulator]), ["tvOrWatchOnly", "fallbackOnly"])
    }

    func testCollectsEveryClauseWithoutConfiguration() {
        let source = """
        #if os(macOS)
        macOSOnly()
        #else
        otherOnly()
        #endif
        """

        XCTAssertEqual(collect(source, []), ["macOSOnly", "otherOnly"])
    }

    func testCollectsEveryClauseWhenAConditionCannotBeEvaluated() {
        for condition in [
            "FOO || os(macOS)",
            "os(macOS) || FOO",
            "canImport(SomeLibrary)",
            "os(macOS) && swift(>=5.9)",
            "os(macOS) || compiler(>=6.0)",
            "os(macOS) || hasFeature(Embedded)",
            "os(Fuchsia) || os(macOS)",
            "os(macOS) || _endian(little)",
            "os(macOS) || targetEnvironment(macabi)",
        ] {
            let source = """
            #if \(condition)
            firstClause()
            #else
            secondClause()
            #endif
            """

            XCTAssertEqual(collect(source, [macOS]), ["firstClause", "secondClause"], condition)
        }
    }

    func testCollectsEveryClauseWhenAnElseifConditionCannotBeEvaluated() {
        let source = """
        #if os(macOS)
        macOSOnly()
        #elseif FOO
        flagOnly()
        #endif
        """

        XCTAssertEqual(collect(source, [macOS]), ["macOSOnly", "flagOnly"])
    }

    func testCollectsNestedBlocksWhole() {
        let source = """
        #if DEBUG
        #if os(macOS)
        debugMacOSOnly()
        #endif
        #endif

        #if os(macOS)
        macOSOnly()
        #if arch(arm64)
        armOnly()
        #else
        intelOnly()
        #endif
        #else
        otherOnly()
        #endif
        """

        XCTAssertEqual(collect(source, [macOS]), ["debugMacOSOnly", "armOnly", "intelOnly", "otherOnly"])
    }

    func testCollectsPostfixPlatformConditionalsOfOtherPlatforms() {
        let source = """
        let view = makeView()
            #if os(iOS)
            .iOSModifier()
            #elseif os(macOS)
            .macOSModifier()
            #endif
        """

        XCTAssertEqual(collect(source, [macOS]), ["iOSModifier"])
    }

    // MARK: - Nested blocks (`platform_conditional_retention: auto`)

    private let nestedSource = """
    #if DEBUG
    #if os(macOS)
    debugMacOSOnly()
    #endif
    #endif

    #if os(macOS)
    macOSOnly()
    #if arch(arm64)
    armOnly()
    #else
    intelOnly()
    #endif
    #elseif os(iOS)
    iOSOnly()
    #if targetEnvironment(simulator)
    simulatorOnly()
    #else
    deviceOnly()
    #endif
    #else
    otherOnly()
    #if os(watchOS)
    watchOnly()
    #endif
    #endif
    """

    /// The condition of a nested block (`os`, `watchOS`) is collected with the clause containing it, as it always was.
    func testNarrowsNestedBlocksWithTheBuildsOfEveryEnclosingClause() {
        XCTAssertEqual(
            collect(nestedSource, [macOS, iOSSimulator]),
            ["debugMacOSOnly", "armOnly", "intelOnly", "simulatorOnly", "deviceOnly", "otherOnly", "os", "watchOS", "watchOnly"]
        )
        XCTAssertEqual(
            collect(nestedSource, [macOS, iOSSimulator], narrowsNestedBlocks: true),
            ["debugMacOSOnly", "intelOnly", "deviceOnly", "otherOnly", "os", "watchOS", "watchOnly"]
        )
    }

    /// With a single build, narrowing nested blocks only skips the clauses that build compiled: every clause it did not
    /// compile, about another platform, is collected as without narrowing.
    func testNarrowingNestedBlocksKeepsEveryClauseASingleBuildDidNotCompile() {
        for configuration in [macOS, iOSSimulator] {
            let allClauses = collect(nestedSource, [configuration])
            let narrowed = collect(nestedSource, [configuration], narrowsNestedBlocks: true)

            XCTAssertTrue(narrowed.isSubset(of: allClauses))
            XCTAssertEqual(
                allClauses.subtracting(narrowed),
                configuration == macOS ? ["armOnly"] : ["simulatorOnly"]
            )
        }
    }

    func testCollectsNestedBlocksWholeWhenAnEnclosingBlockCannotBeEvaluated() {
        let source = """
        #if canImport(SomeLibrary)
        #if os(iOS)
        iOSOnly()
        #else
        otherOnly()
        #endif
        #endif
        """

        XCTAssertEqual(collect(source, [iOSSimulator], narrowsNestedBlocks: true), ["os", "iOS", "iOSOnly", "otherOnly"])
    }
}
