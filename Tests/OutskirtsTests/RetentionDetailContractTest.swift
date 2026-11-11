import Configuration
import Logger
import Shared
@testable import SourceGraph
import SystemPackage
import XCTest

/// Pins the `--explain` retention details of retainers whose wording is otherwise untested.
final class RetentionDetailContractTest: XCTestCase {
    private var configuration: Configuration!
    private var graph: SourceGraph!
    private var file: SourceFile!

    override func setUp() {
        super.setUp()

        configuration = Configuration()
        configuration.explain = ["Widget"]
        graph = SourceGraph(configuration: configuration, logger: Logger(quiet: true, verbose: false, colorMode: .never))
        file = SourceFile(path: FilePath("/Widgets/Widget.swift"), modules: ["Widgets"])
    }

    private func declaration(_ name: String, _ kind: Declaration.Kind, line: Int, attributes: Set<DeclarationAttribute> = [], parent: Declaration? = nil) -> Declaration {
        let decl = Declaration(name: name, kind: kind, usrs: ["usr:\(name)"], location: Location(file: file, line: line, column: 1))
        decl.attributes = attributes
        decl.parent = parent
        parent?.declarations.insert(decl)
        graph.add(decl)
        return decl
    }

    private func swiftVersion() throws -> SwiftVersion {
        try SwiftVersion(shell: ShellImpl(logger: Logger(quiet: true, verbose: false, colorMode: .never)))
    }

    private func details(of decl: Declaration) -> [String?] {
        graph.retentionReasons[decl, default: []].map(\.detail)
    }

    func testLinkageAttributeRetainerDetail() throws {
        let ext = declaration("Widget", .extensionClass, line: 1, attributes: [DeclarationAttribute(name: "implementation", arguments: nil)])

        try LinkageAttributeRetainer(graph: graph, configuration: configuration, swiftVersion: swiftVersion()).mutate()

        XCTAssertEqual(details(of: ext), ["linkage attribute (@_cdecl, @_silgen_name, @_used or @_section)"])
    }

    func testUnusedParameterRetainerDetail() throws {
        configuration.retainUnusedParametersWithoutDefault = true
        let function = declaration("render(widget:)", .functionFree, line: 1)
        let param = declaration("widget", .varParameter, line: 1, parent: function)

        try UnusedParameterRetainer(graph: graph, configuration: configuration, swiftVersion: swiftVersion()).mutate()

        XCTAssertEqual(details(of: param), ["parameter that must be kept for the function signature"])
    }

    func testInterfaceBuilderPropertyRetainerDetail() {
        let action = declaration("click()", .functionMethodInstance, line: 1, attributes: [DeclarationAttribute(name: "IBAction", arguments: nil)])

        InterfaceBuilderPropertyRetainer(graph: graph).retainActionsSentToFirstResponder(["click"])

        XCTAssertEqual(details(of: action), ["referenced by an Interface Builder file"])
    }
}
