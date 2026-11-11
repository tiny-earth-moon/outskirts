import Configuration
import Foundation
import Shared

protocol SourceGraphMutator: AnyObject {
    init(graph: SourceGraph, configuration: Configuration, swiftVersion: SwiftVersion)
    func mutate() throws
}

/// A mutator that only needs the graph.
protocol GraphOnlyMutator: SourceGraphMutator {
    init(graph: SourceGraph)
}

extension GraphOnlyMutator {
    init(graph: SourceGraph, configuration _: Configuration, swiftVersion _: SwiftVersion) {
        self.init(graph: graph)
    }
}
