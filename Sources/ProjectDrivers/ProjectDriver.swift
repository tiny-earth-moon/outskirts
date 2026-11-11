import Foundation
import Indexer
import IndexStore
import Logger
import SystemPackage

public protocol ProjectDriver {
    func build() throws
    func plan(logger: ContextualLogger) throws -> IndexPlan
}

public extension ProjectDriver {
    func build() throws {}

    func plan(logger _: ContextualLogger) throws -> IndexPlan {
        IndexPlan(sourceFiles: [:])
    }
}

/// The index stores a plan reads: the configured ones, otherwise the one the driver derives from its build.
func resolveIndexStorePaths(configured: [FilePath], derive: () throws -> FilePath) rethrows -> Set<FilePath> {
    if !configured.isEmpty {
        return Set(configured)
    }
    return try [derive()]
}
