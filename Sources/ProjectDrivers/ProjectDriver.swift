import Foundation
import Indexer
import IndexStore
import Logger

public protocol ProjectDriver {
    func build() throws
    func plan(logger: ContextualLogger) throws -> IndexPlan
    /// The names of the builds scanned together when the `variants` setting is not `default`, empty otherwise.
    var builtVariants: [String] { get }
    /// Why some builds of the `variants` setting were not scanned, such as an SDK that is not installed.
    var skippedVariants: [String] { get }
}

public extension ProjectDriver {
    func build() throws {}

    func plan(logger _: ContextualLogger) throws -> IndexPlan {
        IndexPlan(sourceFiles: [:])
    }

    var builtVariants: [String] {
        []
    }

    var skippedVariants: [String] {
        []
    }
}
