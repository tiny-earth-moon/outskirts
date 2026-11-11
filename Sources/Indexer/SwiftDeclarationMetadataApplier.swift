import Configuration
import Logger
import SourceGraph
import SyntaxAnalysis

/// Completes a file's declarations from their syntax: attributes, modifiers, types and reference roles, the unused
/// parameters of functions, and the retention asked by comment commands.
struct SwiftDeclarationMetadataApplier {
    let graph: SourceGraphMutex
    let logger: ContextualLogger
    let configuration: Configuration
    let retainAllDeclarations: Bool

    func apply(
        to declarations: [Declaration],
        using declarationVisitor: DeclarationSyntaxVisitor,
        syntaxVisitor: MultiplexingSyntaxVisitor
    ) {
        visitDeclarations(declarations, using: declarationVisitor)
        identifyUnusedParameters(of: declarations, using: syntaxVisitor)
        applyCommentCommands(to: declarations, using: syntaxVisitor)
    }

    // MARK: - Private

    private func visitDeclarations(_ declarations: [Declaration], using declarationVisitor: DeclarationSyntaxVisitor) {
        let declarationsByLocation = declarationVisitor.resultsByLocation

        for decl in declarations {
            guard let result = declarationsByLocation[decl.location] else { continue }

            applyDeclarationMetadata(to: decl, with: result)
        }
    }

    private func applyDeclarationMetadata(to decl: Declaration, with result: DeclarationSyntaxVisitor.Result) {
        graph.withLock { _ in
            if let accessibility = result.accessibility {
                decl.accessibility = .init(value: accessibility, isExplicit: true)
            }

            decl.attributes = Set(result.attributes)
            decl.modifiers = Set(result.modifiers)
            decl.commentCommands = Set(result.commentCommands)
            decl.declaredType = result.variableType
            if result.variableType == nil, decl.kind.isVariableKind {
                decl.inferredType = PropertyTypeDemangler.type(of: decl.usrs)
            }
            decl.isOptionalType = result.isOptionalType
            decl.hasNonNilInitialValue = result.hasNonNilInitialValue
            decl.isInitializedByCall = result.isInitializedByCall
            decl.isInitializedByReference = result.isInitializedByReference

            decl.hasGenericFunctionReturnedMetatypeParameters = result.hasGenericFunctionReturnedMetatypeParameters
            decl.isActor = result.isActor
            decl.isConstant = result.isConstant
            decl.hasBody = result.hasBody

            for ref in decl.references.union(decl.related) {
                if result.inheritedTypeLocations.contains(ref.location) {
                    if decl.kind.isConformableKind, ref.declarationKind == .protocol {
                        ref.role = .conformedType
                    } else if decl.kind == .protocol, ref.declarationKind == .protocol {
                        ref.role = .refinedProtocolType
                    } else if decl.kind == .class || decl.kind == .associatedtype {
                        ref.role = .inheritedType
                    }
                } else if result.variableTypeLocations.contains(ref.location) {
                    ref.role = .varType
                } else if result.returnTypeLocations.contains(ref.location) {
                    ref.role = .returnType
                } else if result.throwTypeLocations.contains(ref.location) {
                    ref.role = .throwType
                } else if result.parameterTypeLocations.contains(ref.location) {
                    ref.role = .parameterType
                } else if result.genericParameterLocations.contains(ref.location) {
                    ref.role = .genericParameterType
                } else if result.genericConformanceRequirementLocations.contains(ref.location) {
                    ref.role = .genericRequirementType
                } else if result.variableInitFunctionCallLocations.contains(ref.location) {
                    ref.role = .variableInitFunctionCall
                } else if result.functionCallMetatypeArgumentLocations.contains(ref.location) {
                    ref.role = .functionCallMetatypeArgument
                } else if result.typeInitializerLocations.contains(ref.location) {
                    ref.role = .initializerType
                } else if result.variableInitExprLocations.contains(ref.location) {
                    ref.role = .initializerType
                }
            }
        }
    }

    private func identifyUnusedParameters(of declarations: [Declaration], using syntaxVisitor: MultiplexingSyntaxVisitor) {
        let functionDecls = declarations.filter(\.kind.isFunctionKind)
        let functionDeclsByLocation = functionDecls.reduce(into: [Location: Declaration]()) {
            $0[$1.location] = $1
        }

        // Build a map of ignored param names per function, and track functions with ignored
        // params so ScanResultBuilder can efficiently detect superfluous ignores.
        var ignoredParamsByLocation: [Location: [String]] = [:]
        for functionDecl in functionDecls {
            let ignoredParamNames = functionDecl.commentCommands.ignoredParameterNames
            if !ignoredParamNames.isEmpty {
                ignoredParamsByLocation[functionDecl.location] = ignoredParamNames
                graph.withLock { $0.markHasIgnoredParameters(functionDecl) }
            }
        }

        let analyzer = UnusedParameterAnalyzer()
        let paramsByFunction = analyzer.analyze(
            file: syntaxVisitor.sourceFile,
            syntax: syntaxVisitor.syntax,
            locationConverter: syntaxVisitor.locationConverter,
            parseProtocols: true
        )

        for (function, params) in paramsByFunction {
            guard let functionDecl = functionDeclsByLocation[function.location] else {
                // The declaration may not exist if the code was not compiled due to build conditions, e.g #if.
                logger.debug("Failed to associate indexed function for parameter function '\(function.name)' at \(function.location).")
                continue
            }

            let ignoredParamNames = ignoredParamsByLocation[functionDecl.location] ?? []

            graph.withLock { graph in
                for param in params {
                    let paramDecl = param.makeDeclaration(withParent: functionDecl)
                    functionDecl.unusedParameters.insert(paramDecl)
                    graph.add(paramDecl)

                    if retainAllDeclarations || (functionDecl.isObjcAccessible && configuration.retainObjcAccessible) {
                        graph.markRetained(paramDecl, reason: RetentionReason(retainer: "Indexer", detail: retainAllDeclarations ? "retain_files" : "retain_objc_accessible"))
                    } else if ignoredParamNames.contains(param.name.text) {
                        graph.markRetained(paramDecl, reason: RetentionReason(retainer: "CommentCommand", detail: "outskirts:ignore:parameters"))
                        graph.markCommandIgnored(paramDecl, kind: .declaration)
                    }
                }
            }
        }
    }

    private func applyCommentCommands(to declarations: [Declaration], using syntaxVisitor: MultiplexingSyntaxVisitor) {
        let fileCommands = syntaxVisitor.parseComments()

        if fileCommands.contains(.ignoreAll) {
            commandIgnore(declarations, kind: .file)
        } else {
            for decl in declarations where decl.commentCommands.contains(.ignore) {
                commandIgnore([decl], kind: .declaration)
            }
        }
    }

    private static func commentCommandDetail(_ kind: CommandIgnoreKind) -> String {
        switch kind {
        case .declaration: "outskirts:ignore (or periphery:ignore) on the declaration or an enclosing one"
        case .file: "outskirts:ignore:all (or periphery:ignore:all) in the file"
        }
    }

    private func commandIgnore(_ decls: [Declaration], kind: CommandIgnoreKind) {
        for decl in decls {
            graph.withLock { graph in
                let reason = RetentionReason(retainer: "CommentCommand", detail: Self.commentCommandDetail(kind))
                graph.markRetained(decl, reason: reason)
                decl.unusedParameters.forEach { graph.markRetained($0, reason: reason) }

                graph.markCommandIgnored(decl, kind: kind)
                decl.unusedParameters.forEach { graph.markCommandIgnored($0, kind: kind) }
            }
            commandIgnore(Array(decl.declarations), kind: kind)
        }
    }
}
