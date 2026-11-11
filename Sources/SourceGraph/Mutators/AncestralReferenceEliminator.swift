import Configuration
import Foundation
import Shared

final class AncestralReferenceEliminator: GraphOnlyMutator {
    private let graph: SourceGraph

    init(graph: SourceGraph) {
        self.graph = graph
    }

    func mutate() {
        for declaration in graph.rootDeclarations {
            eliminateAncestralReferences(in: declaration, stack: declaration.usrs)
        }
    }

    private func eliminateAncestralReferences(in declaration: Declaration, stack: Set<String>) {
        guard !graph.isRetained(declaration) else { return }

        eliminateAncestralReferences(in: declaration.references, stack: stack)

        for childDeclaration in declaration.declarations {
            let newStack = stack.union(childDeclaration.usrs)
            eliminateAncestralReferences(in: childDeclaration, stack: newStack)
        }
    }

    private func eliminateAncestralReferences(in references: Set<Reference>, stack: Set<String>) {
        for reference in references {
            if stack.contains(reference.usr) {
                graph.remove(reference, discardedBy: Self.self, detail: "self-reference, written inside the declaration it refers to")
            }
        }
    }
}
