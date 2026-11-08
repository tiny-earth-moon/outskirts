import Configuration
import Foundation
import Shared

final class PubliclyAccessibleRetainer: SourceGraphMutator {
    private let graph: SourceGraph
    private let configuration: Configuration
    private let noRetainSPIAttributes: [DeclarationAttribute]

    required init(graph: SourceGraph, configuration: Configuration, swiftVersion _: SwiftVersion) {
        self.graph = graph
        self.configuration = configuration
        noRetainSPIAttributes = configuration.noRetainSPI.map { DeclarationAttribute(name: "_spi", arguments: $0) }
    }

    func mutate() {
        guard configuration.retainsPublicDeclarations else { return }

        let declarations = Declaration.Kind.accessibleKinds.union([.macro, .associatedtype]).flatMap {
            graph.declarations(ofKind: $0)
        }

        // The setting that retains each public declaration, nil when none does.
        let publicDeclarations: [(declaration: Declaration, key: String)] = declarations.compactMap { declaration in
            guard declaration.accessibility.value == .public || declaration.accessibility.value == .open,
                  let key = configuration.settings(for: declaration).publicRetentionKey
            else { return nil }

            return (declaration, key)
        }

        // Only filter if noRetainSPI is configured (performance optimization)
        let declarationsToRetain = if configuration.noRetainSPI.isEmpty {
            publicDeclarations
        } else {
            publicDeclarations.filter { $0.declaration.attributes.isDisjoint(with: noRetainSPIAttributes) }
        }

        for (declaration, key) in declarationsToRetain {
            graph.markRetained(declaration, reason: RetentionReason(Self.self, key))

            // Enum cases inherit the accessibility of the enum.
            if declaration.kind == .enum {
                declaration.declarations
                    .filter { $0.kind == .enumelement }
                    .forEach { graph.markRetained($0, reason: RetentionReason(Self.self, "\(key), case of a public enum")) }
            }
        }
    }
}
