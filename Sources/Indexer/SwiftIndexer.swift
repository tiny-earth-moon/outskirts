import Configuration
import FilenameMatcher
import Foundation
import IndexStore
import Logger
import Shared
import SourceGraph
import SyntaxAnalysis
import SystemPackage

public struct IndexUnit {
    let store: IndexStore
    let unit: UnitReader
}

final class SwiftIndexer {
    private let sourceFiles: [SourceFile: [IndexUnit]]
    private let graph: SourceGraphMutex
    private let logger: ContextualLogger
    private let configuration: Configuration
    private let swiftVersion: SwiftVersion

    required init(
        sourceFiles: [SourceFile: [IndexUnit]],
        graph: SourceGraphMutex,
        logger: ContextualLogger,
        configuration: Configuration,
        swiftVersion: SwiftVersion
    ) {
        self.sourceFiles = sourceFiles
        self.graph = graph
        self.logger = logger.contextualized(with: "swift")
        self.configuration = configuration
        self.swiftVersion = swiftVersion
    }

    func perform() throws {
        let jobs = sourceFiles.map { file, units -> Job in
            Job(
                sourceFile: file,
                units: units,
                retainAllDeclarations: configuration.retainFilesMatchers.anyMatch(filename: file.path.string),
                graph: graph,
                logger: logger,
                configuration: configuration,
                swiftVersion: swiftVersion
            )
        }

        let verbose = configuration.verbose
        let logger = logger
        let phaseOneInterval = logger.beginInterval("index:swift:phase:one")

        try JobPool(jobs: jobs).forEach { job in
            if verbose {
                let phaseOneLogger = logger.contextualized(with: "phase:one")
                let elapsed = try Benchmark.measure { try job.phaseOne() }
                SwiftIndexer.debug(logger: phaseOneLogger, sourceFile: job.sourceFile, elapsed: elapsed)
            } else {
                try job.phaseOne()
            }
        }

        logger.endInterval(phaseOneInterval)

        let phaseTwoInterval = logger.beginInterval("index:swift:phase:two")

        try JobPool(jobs: jobs).forEach { job in
            if verbose {
                let phaseTwoLogger = logger.contextualized(with: "phase:two")
                let elapsed = try Benchmark.measure { try job.phaseTwo() }
                SwiftIndexer.debug(logger: phaseTwoLogger, sourceFile: job.sourceFile, elapsed: elapsed)
            } else {
                try job.phaseTwo()
            }
        }

        logger.endInterval(phaseTwoInterval)
    }

    // MARK: - Private

    private static func debug(logger: ContextualLogger, sourceFile: SourceFile, elapsed: String) {
        let modules = sourceFile.modules.joined(separator: ", ")
        logger.debug("\(sourceFile.path.string) (\(modules)) (\(elapsed)s)")
    }

    /// `@unchecked Sendable` invariant: `JobPool` hands each job to one worker at a time, and a phase's workers all
    /// finish before the next phase starts, so the job's own state, including the components it owns, and its source
    /// file, which no other job holds, are never reached from two threads at once. The graph is only reached through
    /// `SourceGraphMutex`; the configuration and the index units are only read. Those types are not `Sendable`, so the
    /// compiler cannot check this.
    private final class Job: @unchecked Sendable {
        let sourceFile: SourceFile

        private let units: [IndexUnit]
        private let graph: SourceGraphMutex
        private let logger: ContextualLogger
        private let configuration: Configuration
        private let retainAllDeclarations: Bool
        private let swiftVersion: SwiftVersion
        private var declarationGraph: SwiftDeclarationGraphBuilder
        private var referenceSites = SwiftIndexStoreReader.ReferenceSites()

        required init(
            sourceFile: SourceFile,
            units: [IndexUnit],
            retainAllDeclarations: Bool,
            graph: SourceGraphMutex,
            logger: ContextualLogger,
            configuration: Configuration,
            swiftVersion: SwiftVersion
        ) {
            self.sourceFile = sourceFile
            self.units = units
            self.retainAllDeclarations = retainAllDeclarations
            self.graph = graph
            self.logger = logger
            self.configuration = configuration
            self.swiftVersion = swiftVersion
            declarationGraph = SwiftDeclarationGraphBuilder(
                graph: graph,
                configuration: configuration,
                retainAllDeclarations: retainAllDeclarations
            )
        }

        /// Phase one reads the index store and establishes the declaration hierarchy and the majority of references.
        /// Some references may depend upon declarations in other files, and thus their association is deferred until
        /// phase two.
        func phaseOne() throws {
            let records = try SwiftIndexStoreReader(sourceFile: sourceFile, units: units, configuration: configuration).read()
            referenceSites = records.referenceSites
            declarationGraph.addDeclarations(from: records)
        }

        /// Phase two associates latent references, and performs other actions that depend on the completed source graph.
        func phaseTwo() throws {
            if !configuration.disableUnusedImportAnalysis {
                graph.withLock { graph in
                    graph.addIndexedSourceFile(sourceFile)
                    graph.addIndexedModules(sourceFile.modules)
                }
            }

            let multiplexingSyntaxVisitor = try MultiplexingSyntaxVisitor(file: sourceFile, swiftVersion: swiftVersion)
            let declarationSyntaxVisitor = multiplexingSyntaxVisitor.add(DeclarationSyntaxVisitor.self)
            let syntaxFacts = SwiftSyntaxFactCollector(
                registeringOn: multiplexingSyntaxVisitor,
                units: units,
                graph: graph,
                logger: logger,
                configuration: configuration,
                retainAllDeclarations: retainAllDeclarations
            )

            multiplexingSyntaxVisitor.visit()

            syntaxFacts.collect(using: referenceSites)
            referenceSites = .init()

            declarationGraph.associateReferences(
                using: declarationSyntaxVisitor,
                excluding: TopLevelCodeCollector.collect(
                    from: multiplexingSyntaxVisitor.syntax,
                    locationConverter: multiplexingSyntaxVisitor.locationConverter
                )
            )
            SwiftDeclarationMetadataApplier(
                graph: graph,
                logger: logger,
                configuration: configuration,
                retainAllDeclarations: retainAllDeclarations
            ).apply(
                to: declarationGraph.declarations,
                using: declarationSyntaxVisitor,
                syntaxVisitor: multiplexingSyntaxVisitor
            )
        }
    }
}
