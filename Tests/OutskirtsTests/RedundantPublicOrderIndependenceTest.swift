import Configuration
import Logger
import Shared
@testable import SourceGraph
import SystemPackage
import XCTest

final class RedundantPublicOrderIndependenceTest: XCTestCase {
    /// The verdict on a refining protocol depends on the verdict on the protocol it refines. The root declarations are
    /// a Set, so many copies of the pattern make both visiting orders occur in one run.
    func testRefiningProtocolVerdictDoesNotDependOnVisitOrder() throws {
        let logger = Logger(quiet: true, verbose: false, colorMode: .never)
        let configuration = Configuration()
        let graph = SourceGraph(configuration: configuration, logger: logger)
        let swiftVersion = try SwiftVersion(shell: ShellImpl(logger: logger))
        var pairs: [(parent: Declaration, child: Declaration)] = []

        for index in 0 ..< 32 {
            let file = SourceFile(path: FilePath("/tmp/order\(index).swift"), modules: ["Lib"])
            let otherFile = SourceFile(path: FilePath("/tmp/use\(index).swift"), modules: ["App"])
            func location(_ line: Int, _ file: SourceFile = file) -> Location {
                Location(file: file, line: line, column: 1)
            }
            func declaration(_ kind: Declaration.Kind, _ name: String, _ usr: String, line: Int, isPublic: Bool) -> Declaration {
                let decl = Declaration(name: name, kind: kind, usrs: [usr], location: location(line))
                if isPublic {
                    decl.accessibility = .init(value: .public, isExplicit: true)
                }
                graph.add(decl)
                return decl
            }
            func reference(
                _ kind: Reference.Kind,
                _ declarationKind: Declaration.Kind,
                _ name: String,
                _ usr: String,
                from parent: Declaration,
                at referenceLocation: Location
            ) {
                let ref = Reference(name: name, kind: kind, declarationKind: declarationKind, usr: usr, location: referenceLocation)
                ref.parent = parent
                graph.add(ref, from: parent)
            }

            let parent = declaration(.protocol, "Parent\(index)", "p\(index)", line: 1, isPublic: true)
            let requirement = declaration(.varInstance, "label", "r\(index)", line: 2, isPublic: false)
            requirement.parent = parent
            parent.declarations.insert(requirement)

            let child = declaration(.protocol, "Child\(index)", "c\(index)", line: 4, isPublic: true)
            reference(.related, .protocol, "Parent\(index)", "p\(index)", from: child, at: location(4))

            let ext = declaration(.extensionProtocol, "Child\(index)", "e\(index)", line: 6, isPublic: false)
            reference(.normal, .protocol, "Child\(index)", "c\(index)", from: ext, at: location(6))
            let witness = declaration(.varInstance, "label", "w\(index)", line: 7, isPublic: true)
            witness.parent = ext
            ext.declarations.insert(witness)
            reference(.related, .varInstance, "label", "r\(index)", from: witness, at: location(7))

            let conformer = declaration(.struct, "Conformer\(index)", "s\(index)", line: 10, isPublic: true)
            reference(.related, .protocol, "Child\(index)", "c\(index)", from: conformer, at: location(10))
            let user = declaration(.varGlobal, "user\(index)", "u\(index)", line: 1, isPublic: false)
            reference(.normal, .struct, "Conformer\(index)", "s\(index)", from: user, at: location(1, otherFile))

            pairs.append((parent, child))
        }

        graph.indexingComplete()
        try RedundantExplicitPublicAccessibilityMarker(graph: graph, configuration: configuration, swiftVersion: swiftVersion).mutate()

        for (parent, child) in pairs {
            XCTAssertNotNil(graph.redundantPublicAccessibility[parent], parent.name)
            // Once the refined protocol is internal, the refining one witnesses no public requirement.
            XCTAssertNotNil(graph.redundantPublicAccessibility[child], child.name)
        }
    }
}
