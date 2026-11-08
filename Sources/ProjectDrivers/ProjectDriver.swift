import Foundation
import Indexer
import IndexStore
import Logger

public protocol ProjectDriver {
    func build() throws
    func plan(logger: ContextualLogger) throws -> IndexPlan
    /// The names of the variants this run built and scanned together when the `variants` setting is not `default`,
    /// empty otherwise, and when the build is skipped or the index store is given.
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
