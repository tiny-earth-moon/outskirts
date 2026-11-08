@testable import Fix
import SourceGraph
import SystemPackage
@testable import TestShared
import XCTest

/// What the `#if` clauses that no scanned build compiled may use: the names they write, the types whose members they
/// reach, and the members they may call without writing their name.
final class UncoveredConditionalNamesTest: FixtureSourceGraphTestCase {
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

    func testFindsTheNamesWrittenInClauses() throws {
        let uncovered = try readIndexedFixture()

        XCTAssertEqual(uncovered.writtenName(of: try declaration("conditionalReleaseOnly()")), "conditionalReleaseOnly")
        XCTAssertEqual(uncovered.writtenName(of: try declaration("conditionalFlagOnly()")), "conditionalFlagOnly")
        XCTAssertNil(uncovered.writtenName(of: try declaration("unconditional()")))
    }

    func testFindsWhatClausesReachWithoutNamingIt() throws {
        let uncovered = try readIndexedFixture()

        // Overridden in the clause.
        XCTAssertEqual(uncovered.writtenName(of: try declaration("conditionalHook()")), "conditionalHook")
        // Extended in the clause.
        XCTAssertEqual(uncovered.writtenName(of: try declaration("ConditionalOnlyExtendedInRelease")), "ConditionalOnlyExtendedInRelease")
        // A conformance added in the clause uses it.
        XCTAssertEqual(uncovered.reachingType(of: try declaration("description")), "ConditionalDescribed")
        // The clause may call it as `grid[1]`.
        XCTAssertTrue(uncovered.mayUseImplicitly(try declaration("subscript(_:)")))

        let notReached = try declaration("conditionalNotReached()")
        XCTAssertNil(uncovered.writtenName(of: notReached))
        XCTAssertNil(uncovered.reachingType(of: notReached))
        XCTAssertFalse(uncovered.mayUseImplicitly(notReached))
    }

    func testRestrictiveTargetsReachedByTheClausesAreSkipped() throws {
        let file = SourceFile(path: "/Sources/Lib/Release.swift", modules: ["Lib"])
        let uncovered = UncoveredConditionalNames(names: ["releaseOnly"], filesWithCode: [file.path])
        let location = Location(file: file, line: 1, column: 8)
        let otherLocation = Location(file: SourceFile(path: "/Sources/Lib/Other.swift", modules: ["Lib"]), line: 1, column: 8)

        // A call in the clause may need an import that the index shows unused.
        XCTAssertEqual(uncovered.skipReason(for: Declaration(name: "Helpers", kind: .module, usrs: ["Helpers"], location: location), rule: .unusedImport), .uncoveredConditionalCode)
        XCTAssertNil(uncovered.skipReason(for: Declaration(name: "Helpers", kind: .module, usrs: ["Helpers-other"], location: otherLocation), rule: .unusedImport))
        XCTAssertEqual(uncovered.skipReason(for: Declaration(name: "releaseOnly()", kind: .functionFree, usrs: ["s:releaseOnly"], location: otherLocation), rule: .redundantPublic), .uncoveredConditionalName)
        XCTAssertNil(uncovered.skipReason(for: Declaration(name: "kept()", kind: .functionFree, usrs: ["s:kept"], location: otherLocation), rule: .redundantPublic))
    }

    // MARK: - Private

    private func readIndexedFixture() throws -> UncoveredConditionalNames {
        analyze {}
        return try UncoveredConditionalNames(graph: Self.graph)
    }

    private func declaration(_ name: String) throws -> Declaration {
        try XCTUnwrap(Self.graph.allDeclarations.first { $0.name == name && $0.location.file.path == testFixturePath }, "\(name) is not declared in \(testFixturePath)")
    }
}
