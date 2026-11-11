import Configuration
import Logger
import SourceGraph
import SyntaxAnalysis

/// Collects the facts of a source file that its syntax holds outside of any declaration: imports, platform
/// conditionals, names used at runtime (assets, localized strings, Metal functions), synthesized uses, key paths and
/// empty extensions, and adds them to the graph.
struct SwiftSyntaxFactCollector {
    private let sourceFile: SourceFile
    private let units: [IndexUnit]
    private let graph: SourceGraphMutex
    private let logger: ContextualLogger
    private let configuration: Configuration
    private let retainAllDeclarations: Bool
    private let multiplexingSyntaxVisitor: MultiplexingSyntaxVisitor
    private let importSyntaxVisitor: ImportSyntaxVisitor
    private let localizedStringSyntaxVisitor: LocalizedStringSyntaxVisitor?
    private let emptyExtensionSyntaxVisitor: EmptyExtensionSyntaxVisitor?

    /// Adds the visitors the collector reads to `multiplexingSyntaxVisitor`, which must not have visited yet.
    init(
        registeringOn multiplexingSyntaxVisitor: MultiplexingSyntaxVisitor,
        units: [IndexUnit],
        graph: SourceGraphMutex,
        logger: ContextualLogger,
        configuration: Configuration,
        retainAllDeclarations: Bool
    ) {
        sourceFile = multiplexingSyntaxVisitor.sourceFile
        self.units = units
        self.graph = graph
        self.logger = logger
        self.configuration = configuration
        self.retainAllDeclarations = retainAllDeclarations
        self.multiplexingSyntaxVisitor = multiplexingSyntaxVisitor
        importSyntaxVisitor = multiplexingSyntaxVisitor.add(ImportSyntaxVisitor.self)
        localizedStringSyntaxVisitor = configuration.disableUnusedLocalizedStringAnalysis
            ? nil
            : multiplexingSyntaxVisitor.add(LocalizedStringSyntaxVisitor.self)
        emptyExtensionSyntaxVisitor = configuration.enableEmptyExtensionAnalysis
            ? multiplexingSyntaxVisitor.add(EmptyExtensionSyntaxVisitor.self)
            : nil
    }

    /// Reads the visitors after the visit, matching runtime names against the index facts in `referenceSites`.
    func collect(using referenceSites: SwiftIndexStoreReader.ReferenceSites) {
        sourceFile.importStatements = importSyntaxVisitor.importStatements
        sourceFile.usesDistributedModifier = importSyntaxVisitor.usesDistributedModifier
        sourceFile.importsSwiftTesting = importSyntaxVisitor.importStatements.contains(where: { $0.module == "Testing" })

        if !configuration.disableUnusedImportAnalysis {
            for stmt in sourceFile.importStatements where stmt.isExported {
                graph.withLock { graph in
                    graph.addExportedModule(stmt.module, exportedBy: sourceFile.modules)
                }
            }
        }

        // The platform conditionals of generated asset symbols only name the generated symbols themselves,
        // which would retain every asset.
        if !configuration.disablePlatformConditionalRetention,
           !configuration.isAnalyzedGeneratedAssetSymbolsFile(sourceFile.path)
        {
            let names = PlatformConditionalNameCollector.collect(
                from: multiplexingSyntaxVisitor.syntax,
                configurations: platformBuildConfigurations()
            )

            if !names.isEmpty {
                graph.withLock { $0.addPlatformConditionalNames(names, in: sourceFile) }
            }
        }

        let parameterAttributeNames = ParameterAttributeNameCollector.collect(from: multiplexingSyntaxVisitor.syntax)

        if !parameterAttributeNames.isEmpty {
            graph.withLock { $0.addParameterAttributeNames(parameterAttributeNames) }
        }

        let collectsAssetNames = configuration.detectsUnusedAssetCatalogSymbols
            && !configuration.isAnalyzedGeneratedAssetSymbolsFile(sourceFile.path)
        let stringLiterals = collectsAssetNames || localizedStringSyntaxVisitor != nil
            ? StringLiteralCollector.collect(from: multiplexingSyntaxVisitor.syntax)
            : []

        // Assets can be loaded by name, e.g. `Color("AccentColor")` or `UIColor(named: "AccentColor")`.
        if collectsAssetNames, !stringLiterals.isEmpty {
            graph.withLock { $0.addAssetCatalogNameReferences(stringLiterals) }
        }

        if let localizedStringSyntaxVisitor {
            collectUsedLocalizedStringKeys(using: localizedStringSyntaxVisitor, calleeUsrsByPosition: referenceSites.calleeUsrsByPosition)

            if !stringLiterals.isEmpty {
                graph.withLock { graph in
                    if configuration.localizedStringKeyLiteralMatch {
                        graph.addUsedLocalizedStringKeys(stringLiterals)
                    } else {
                        graph.addLocalizedStringKeyCandidateLiterals(stringLiterals, file: sourceFile)
                    }
                }
            }
        }

        if configuration.detectUnusedMetalFunctions {
            collectMetalFunctionNameReferences(descriptorNameLocations: referenceSites.metalFunctionDescriptorNameLocations)
        }

        if configuration.retainSynthesizedUses {
            let uses = SynthesizedUseCollector.collect(
                from: multiplexingSyntaxVisitor.syntax,
                file: sourceFile,
                locationConverter: multiplexingSyntaxVisitor.locationConverter
            )

            if !uses.isEmpty {
                graph.withLock { $0.addSynthesizedUses(uses) }
            }
        }

        if configuration.enableUnassignedOptionalAnalysis {
            let locations = KeyPathComponentCollector.collect(
                from: multiplexingSyntaxVisitor.syntax,
                file: sourceFile,
                locationConverter: multiplexingSyntaxVisitor.locationConverter
            )

            if !locations.isEmpty {
                graph.withLock { $0.addKeyPathComponentLocations(locations) }
            }
        }

        if let emptyExtensionSyntaxVisitor {
            markEmptyExtensions(using: emptyExtensionSyntaxVisitor, fileCommands: multiplexingSyntaxVisitor.parseComments())
        }
    }

    // MARK: - Private

    /// The configurations the file's units were compiled for, or none when one of their triples is not understood,
    /// in which case every clause of the file's platform conditionals is collected.
    private func platformBuildConfigurations() -> [PlatformBuildConfiguration] {
        var configurations: Set<PlatformBuildConfiguration> = []

        for indexUnit in units {
            guard let configuration = PlatformBuildConfiguration(triple: indexUnit.unit.target) else { return [] }

            configurations.insert(configuration)
        }

        return Array(configurations)
    }

    /// Calls are recognized from syntax, an assignment to a `name` property only when the index store records
    /// a reference to `MTLFunctionDescriptor.name` at its `name` token.
    private func collectMetalFunctionNameReferences(descriptorNameLocations: Set<Location>) {
        let collected = MetalFunctionNameCollector.collect(
            from: multiplexingSyntaxVisitor.syntax,
            file: sourceFile,
            locationConverter: multiplexingSyntaxVisitor.locationConverter
        )
        let references = collected.candidates.compactMapSet { candidate -> MetalFunctionNameReference? in
            guard let propertyLocation = candidate.propertyLocation else { return candidate.reference }

            return descriptorNameLocations.contains(propertyLocation) ? candidate.reference : nil
        }

        let runtimeLibrarySites = Set(collected.runtimeLibrarySites)

        guard !references.isEmpty || !runtimeLibrarySites.isEmpty else { return }

        graph.withLock {
            $0.addMetalFunctionNameReferences(references)
            $0.addMetalRuntimeLibrarySites(runtimeLibrarySites)
        }
    }

    private func collectUsedLocalizedStringKeys(
        using visitor: LocalizedStringSyntaxVisitor,
        calleeUsrsByPosition: [LocalizedStringCalleePosition: Set<String>]
    ) {
        var keys = visitor.usedStringKeys

        for callSite in visitor.callSites {
            let position = LocalizedStringCalleePosition(line: callSite.line, column: callSite.column)
            let calleeUsrs = calleeUsrsByPosition[position] ?? []
            keys.formUnion(LocalizedStringCallResolver.usedKeys(for: callSite, calleeUsrs: calleeUsrs))
        }

        collectRuntimeLocalizedStringKeys(visitor.unresolvedKeys)

        guard !keys.isEmpty else { return }

        graph.withLock { $0.addUsedLocalizedStringKeys(keys) }
    }

    /// Keys built at runtime retain the catalogue keys starting with their literal prefix: in the catalogues of
    /// the calling module for a `bundle: .module` lookup, in every catalogue otherwise. A key without a literal
    /// prefix may be any key: it retains only the keys equal to a string literal of its file unless
    /// `retain_runtime_localized_keys` is set, and its call site is recorded to be reported.
    private func collectRuntimeLocalizedStringKeys(_ unresolvedKeys: [LocalizedStringUnresolvedKey]) {
        guard !unresolvedKeys.isEmpty else { return }

        var modulePrefixes: Set<String> = []
        var globalPrefixes: Set<String> = []
        var unprefixedLocations: Set<Location> = []

        for unresolvedKey in unresolvedKeys {
            if unresolvedKey.prefix.isEmpty {
                unprefixedLocations.insert(Location(file: sourceFile, line: unresolvedKey.line, column: unresolvedKey.column))
                guard configuration.retainRuntimeLocalizedKeys else { continue }
            }

            let isModuleScoped = unresolvedKey.bundleScope == .module && !sourceFile.modules.isEmpty
            let scope = isModuleScoped ? "catalogues of \(sourceFile.modules.sorted().joined(separator: ", "))" : "all catalogues"
            logger.debug("Runtime localized string key at \(sourceFile.path.string):\(unresolvedKey.line):\(unresolvedKey.column), retaining keys with prefix '\(unresolvedKey.prefix)' in \(scope)")

            if isModuleScoped {
                modulePrefixes.insert(unresolvedKey.prefix)
            } else {
                globalPrefixes.insert(unresolvedKey.prefix)
            }
        }

        graph.withLock { graph in
            graph.addRuntimeLocalizedStringKeyPrefixes(modulePrefixes, modules: sourceFile.modules)
            graph.addRuntimeLocalizedStringKeyPrefixes(globalPrefixes)
            graph.addUnprefixedRuntimeLocalizedStringKeyLocations(unprefixedLocations)
        }
    }

    private func markEmptyExtensions(using visitor: EmptyExtensionSyntaxVisitor, fileCommands: [CommentCommand]) {
        guard !retainAllDeclarations, !fileCommands.contains(.ignoreAll) else { return }

        let emptyExtensions = visitor.results.filter { !$0.commentCommands.contains(.ignore) }

        guard !emptyExtensions.isEmpty else { return }

        graph.withLock { graph in
            for emptyExtension in emptyExtensions {
                graph.markEmptyExtension(extendedTypeName: emptyExtension.extendedTypeName, location: emptyExtension.location)
            }
        }
    }
}
