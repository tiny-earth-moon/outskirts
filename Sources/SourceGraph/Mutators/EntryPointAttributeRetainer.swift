import Configuration
import Foundation
import Shared

final class EntryPointAttributeRetainer: SourceGraphMutator {
    private static let entryPointAttributes: Set<String> = ["main", "UIApplicationMain", "NSApplicationMain"]

    private let graph: SourceGraph

    required init(graph: SourceGraph, configuration _: Configuration, swiftVersion _: SwiftVersion) {
        self.graph = graph
    }

    func mutate() {
        retainAttributedTypes()
        retainTypesWithAttributedExtensions()
    }

    // MARK: - Private

    private func retainAttributedTypes() {
        for declaration in graph.declarations(ofKinds: [.class, .struct, .enum])
            where declaration.hasAttribute(in: Self.entryPointAttributes)
        {
            retainEntryPoint(declaration)

            if declaration.hasAttribute(named: "main") {
                retainMainFunction(in: declaration)
            }
        }
    }

    /// `@main` can be applied to an extension of the entry point type. Extensions are folded into the extended type,
    /// and only remain reachable through the graph's extension index.
    private func retainTypesWithAttributedExtensions() {
        for (extendedDeclaration, extensions) in graph.extensions {
            for extensionDeclaration in extensions
                where extensionDeclaration.hasAttribute(named: "main")
            {
                retainEntryPoint(extendedDeclaration)
                graph.markRetainedWithAncestors(extensionDeclaration)
                retainMainFunction(in: extensionDeclaration)
            }
        }
    }

    private func retainEntryPoint(_ declaration: Declaration) {
        graph.markRetainedWithAncestors(declaration)
        graph.markMainAttributed(declaration)
    }

    /// @main requires a static main() function. When the type does not declare one, it is provided by an extension
    /// of a protocol it conforms to, or by a superclass.
    private func retainMainFunction(in declaration: Declaration) {
        for candidate in [declaration] + graph.inheritedDeclarations(of: declaration) {
            let mainFunctions = ([candidate] + protocolExtensions(of: candidate)).flatMap { Self.mainFunctions(in: $0) }
            guard !mainFunctions.isEmpty else { continue }

            for function in mainFunctions {
                graph.markRetainedWithAncestors(function)
            }
            return
        }
    }

    /// Protocol extensions are not folded into the protocol, which references them instead.
    private func protocolExtensions(of declaration: Declaration) -> [Declaration] {
        guard declaration.kind == .protocol else { return [] }

        return declaration.references
            .filter { $0.declarationKind == .extensionProtocol }
            .compactMap { graph.declaration(withUsr: $0.usr) }
    }

    private static func mainFunctions(in declaration: Declaration) -> [Declaration] {
        declaration.declarations.filter { $0.kind == .functionMethodStatic && $0.name == "main()" }
    }
}
