import Configuration
import Logger
import Shared
import SourceGraph
import SystemPackage

protocol ResourceIndexingStrategy: Sendable {
    static var loggerContext: String { get }

    static func parseFailureDescription(path: FilePath, underlyingError: Error) -> String

    func index(_ path: FilePath, into graph: SourceGraphMutex) throws
}

struct ResourceIndexError: Error, CustomStringConvertible {
    let description: String
}

final class ResourceIndexer<Strategy: ResourceIndexingStrategy> {
    private let files: Set<FilePath>
    private let graph: SourceGraphMutex
    private let logger: ContextualLogger
    private let strategy: Strategy
    private let configuration: Configuration

    init(files: Set<FilePath>, strategy: Strategy, graph: SourceGraphMutex, logger: ContextualLogger, configuration: Configuration) {
        self.files = files
        self.strategy = strategy
        self.graph = graph
        self.logger = logger.contextualized(with: Strategy.loggerContext)
        self.configuration = configuration
    }

    func perform() throws {
        let (includedFiles, excludedFiles) = configuration.filterIndexExcluded(from: files)
        excludedFiles.forEach { self.logger.debug("Excluding \($0.string)") }

        try JobPool(jobs: Array(includedFiles)).forEach { [graph, logger, strategy] path in
            let elapsed = try Benchmark.measure {
                do {
                    try strategy.index(path, into: graph)
                } catch {
                    throw ResourceIndexError(description: Strategy.parseFailureDescription(path: path, underlyingError: error))
                }
            }

            logger.debug("\(path.string) (\(elapsed)s)")
        }
    }
}

extension Configuration {
    func filterIndexExcluded(from files: Set<FilePath>) -> (included: Set<FilePath>, excluded: Set<FilePath>) {
        guard !indexExclude.isEmpty else { return (files, []) }

        let included = files.filter { !isIndexExcluded($0) }
        return (included, files.subtracting(included))
    }
}
