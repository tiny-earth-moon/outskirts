import Configuration
import Foundation
import Shared

/// Retains a stored instance property of type `Void` whose initializer has a side effect: the property only exists to
/// run it when its instance is initialized. The initializer is either a call, or a read of a static or global `Void`
/// property, which runs that property's lazy initializer. Static, global and `lazy` properties are initialized on
/// their first read, so an unread one never runs its initializer and stays reported.
final class SideEffectPropertyRetainer: SourceGraphMutator {
    private static let voidTypes: Set<String> = ["Void", "()", "Swift.Void"]
    private static let lazilyInitializedKinds: Set<Declaration.Kind> = [.varStatic, .varClass, .varGlobal]

    private let graph: SourceGraph

    required init(graph: SourceGraph, configuration _: Configuration, swiftVersion _: SwiftVersion) {
        self.graph = graph
    }

    func mutate() {
        for property in graph.declarations(ofKind: .varInstance) {
            guard !property.modifiers.contains("lazy"),
                  isVoid(property),
                  property.isInitializedByCall || (property.isInitializedByReference && readsLazyVoidProperty(property))
            else { continue }

            graph.markRetained(property, reason: RetentionReason(Self.self, "stored Void property whose initializer runs a side effect"))
        }
    }

    // MARK: - Private

    private func isVoid(_ property: Declaration) -> Bool {
        guard let type = property.declaredType ?? property.inferredType else { return false }

        return Self.voidTypes.contains(type)
    }

    private func readsLazyVoidProperty(_ property: Declaration) -> Bool {
        property.references.contains { reference in
            guard Self.lazilyInitializedKinds.contains(reference.declarationKind),
                  let referenced = graph.declaration(withUsr: reference.usr)
            else { return false }

            return isVoid(referenced)
        }
    }
}
