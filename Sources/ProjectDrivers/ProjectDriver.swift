import Foundation
import Indexer
import IndexStore
import Logger

public protocol ProjectDriver {
    func build() throws
    func plan(logger: ContextualLogger) throws -> IndexPlan
    /// The names of the builds scanned together when the `variants` setting is not `default`, empty otherwise.
    var builtVariants: [String] { get }
}

public extension ProjectDriver {
    func build() throws {}

    func plan(logger _: ContextualLogger) throws -> IndexPlan {
        IndexPlan(sourceFiles: [:])
    }

    var builtVariants: [String] {
        []
    }
}
