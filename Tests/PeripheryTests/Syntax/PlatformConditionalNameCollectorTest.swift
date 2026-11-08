import SourceGraph
import SwiftParser
import SwiftSyntax
@testable import SyntaxAnalysis
import XCTest

final class PlatformConditionalNameCollectorTest: XCTestCase {
    private let macOS = PlatformBuildConfiguration(triple: "arm64-apple-macosx14.0")!
    private let iOSSimulator = PlatformBuildConfiguration(triple: "arm64-apple-ios18.0-simulator")!

    /// The names written as references.
    private func collect(_ source: String, _ configurations: [PlatformBuildConfiguration], narrowsNestedBlocks: Bool = false) -> Set<String> {
        Set(collectEntries(source, configurations, narrowsNestedBlocks: narrowsNestedBlocks).compactMap { entry in
            if case let .reference(name) = entry {
                name
            } else {
                nil
            }
        })
    }

    private func collectEntries(
        _ source: String,
        _ configurations: [PlatformBuildConfiguration],
        narrowsNestedBlocks: Bool = false
    ) -> Set<PlatformConditionalName> {
        Set(PlatformConditionalNameCollector.collect(
            from: Parser.parse(source: source),
            configurations: configurations,
            narrowsNestedBlocks: narrowsNestedBlocks
        ).compactMap(PlatformConditionalName.init(encoded:)))
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

        XCTAssertEqual(collectEntries(source, [macOS]), [
            .reference("lhs"), .reference("<~>"), .reference("rhs"), .reference("-"), .reference("value"),
            .reference("Module"), .reference("unchecked"), .reference("Sendable"), .reference("FixtureProtocol"), .reference("OtherProtocol"),
            .reference("FixtureBase"), .reference("Int"), .reference("index"),
            .conformance(type: "FixtureType", protocol: "Sendable"),
            .conformance(type: "FixtureType", protocol: "FixtureProtocol"),
            .conformance(type: "FixtureType", protocol: "OtherProtocol"),
            .superclass("FixtureBase"),
            .override("update"), .override("size"), .override("subscript"),
        ])
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

        XCTAssertEqual(collectEntries(source, [macOS]), [.otherClauseReference("releaseOnly"), .otherClauseReference("debugOnly")])
    }

    func testEncodedEntriesRoundTrip() {
        let entries: [PlatformConditionalName] = [
            .reference("name"), .reference("<~>"), .conformance(type: "T", protocol: "P"), .override("update"),
            .superclass("Base"), .otherClauseReference("flagOnly"),
        ]

        XCTAssertEqual(entries.map { PlatformConditionalName(encoded: $0.encoded) }, entries)
        XCTAssertNil(PlatformConditionalName(encoded: "`unknown`name"))
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
            "canImport(AppKit)",
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
        #if canImport(UIKit)
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
