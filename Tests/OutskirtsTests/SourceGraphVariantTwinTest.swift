import Configuration
import Logger
import Shared
@testable import SourceGraph
import SystemPackage
import XCTest

final class SourceGraphVariantTwinTest: XCTestCase {
    private let file = SourceFile(path: FilePath("Twins.swift"), modules: ["Twins"])

    private func makeGraph(everyVariant: Bool) -> SourceGraph {
        let configuration = Configuration()
        configuration.everyVariant = everyVariant
        return SourceGraph(configuration: configuration, logger: Logger(quiet: true, verbose: false, colorMode: .never))
    }

    private func makeDeclaration(_ usr: String, line: Int, in file: SourceFile? = nil) -> Declaration {
        Declaration(name: usr, kind: .struct, usrs: [usr], location: Location(file: file ?? self.file, line: line, column: 1))
    }

    private func identities(_ declarations: [Declaration]) -> [ObjectIdentifier] {
        declarations.map(ObjectIdentifier.init)
    }

    func testTheTwinThatSortsFirstIsCanonicalWhateverTheOrderAndParentsEveryChild() {
        for reversed in [false, true] {
            let graph = makeGraph(everyVariant: true)
            let first = makeDeclaration("s:S", line: 2)
            let second = makeDeclaration("s:S", line: 8)
            let child = makeDeclaration("s:S.c", line: 9)
            let added = reversed ? [second, first] : [first, second]

            graph.add(added[0])
            child.parent = added[0]
            added[0].declarations.insert(child)
            graph.add(added[1])

            XCTAssertTrue(graph.declaration(withUsr: "s:S") === first)
            XCTAssertTrue(graph.allDeclarations.first { $0 == first } === first)
            XCTAssertTrue(child.parent === first)
            XCTAssertEqual(first.declarations, [child])
            XCTAssertTrue(second.declarations.isEmpty)
            XCTAssertEqual(Set(identities(graph.withVariantTwins(first))), Set(identities([first, second])))
        }
    }

    func testAUsedTwinMakesTheReferencesOfEveryTwinUsed() throws {
        let logger = Logger(quiet: true, verbose: false, colorMode: .never)
        let swiftVersion = try SwiftVersion(shell: ShellImpl(logger: logger))

        for everyVariant in [true, false] {
            let graph = makeGraph(everyVariant: everyVariant)
            let first = makeDeclaration("s:S", line: 2)
            let second = makeDeclaration("s:S", line: 8)
            let target = makeDeclaration("s:T", line: 20)
            [first, second, target].forEach { graph.add($0) }
            let reference = Reference(
                name: "s:T",
                kind: .normal,
                declarationKind: .struct,
                usr: "s:T",
                location: Location(file: file, line: 9, column: 5)
            )
            reference.parent = second
            graph.add(reference, from: second)
            graph.markRetained(first)
            graph.indexingComplete()

            try UsedDeclarationMarker(graph: graph, configuration: Configuration(), swiftVersion: swiftVersion).mutate()

            XCTAssertEqual(graph.unusedDeclarations.contains(target), !everyVariant, "every_variant: \(everyVariant)")
        }
    }

    func testDeclarationsOfDisjointModulesAreNotTwins() {
        let graph = makeGraph(everyVariant: true)
        let declaration = makeDeclaration("s:S", line: 2)
        let other = makeDeclaration("s:S", line: 2, in: SourceFile(path: FilePath("Other.swift"), modules: ["Other"]))

        graph.add(declaration)
        graph.add(other)

        XCTAssertEqual(graph.withVariantTwins(declaration).count, 1)
    }

    func testRemovingADeclarationForgetsItsTwins() {
        let graph = makeGraph(everyVariant: true)
        let first = makeDeclaration("s:S", line: 2)
        graph.add(first)
        graph.add(makeDeclaration("s:S", line: 8))

        graph.remove(first)

        XCTAssertNil(graph.declaration(withUsr: "s:S"))
        XCTAssertEqual(graph.withVariantTwins(first).count, 1)
    }

    func testWithoutEveryVariantNoTwinIsKept() {
        let graph = makeGraph(everyVariant: false)
        let first = makeDeclaration("s:S", line: 2)
        let second = makeDeclaration("s:S", line: 8)

        graph.add(second)
        graph.add(first)

        XCTAssertTrue(graph.declaration(withUsr: "s:S") === first)
        XCTAssertTrue(graph.allDeclarations.first { $0 == first } === second, "the set keeps the declaration added first")
        XCTAssertEqual(graph.withVariantTwins(second).count, 1)
    }
}
