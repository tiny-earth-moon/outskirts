import Foundation
import SourceGraph
import SwiftIfConfig
import SwiftSyntax

/// Collects the identifiers written inside `#if` blocks conditioned on the target platform
/// (`os()`, `targetEnvironment()`, `arch()`, `canImport()`).
///
/// The index store only contains the code of the compilation condition that was built, so references
/// made from the inactive branches of these blocks are invisible to the indexer. Syntax trees contain
/// every branch, which allows us to know which names are possibly referenced from another platform.
///
/// When the build configurations of the indexed units are known, the clauses that one of them compiled are skipped:
/// their references are already in the index store. A block is only narrowed this way when every condition is made
/// of `os()`, `arch()`, `targetEnvironment()` and `canImport()` checks joined by `!`, `&&` and `||`, when it is not
/// nested in another `#if` block, and when every configuration evaluates it with certainty: `canImport()` is answered
/// for the system modules the platform settles and the project's modules the build compiled, and another module only
/// when it does not decide the clause. Otherwise the whole block is collected.
///
/// With `narrowsNestedBlocks`, a block nested in other `#if` blocks is narrowed too, when every enclosing block can be
/// narrowed: a configuration compiles one of its clauses when it also compiles every enclosing clause. The clauses no
/// configuration compiles are collected exactly as without it.
///
/// With `collectsEveryBlock`, the blocks whose conditions do not involve the platform are collected too, whole as
/// they cannot be evaluated (custom flags, `DEBUG`, `swift()`, `compiler()`...). Without it, their names are collected
/// apart, in `PlatformConditionalNames.otherClauseNames`, which only account for imports.
///
/// Besides the names written as references, operators included, `collected` tells what a clause uses without writing
/// its name: the members it overrides and the types it inherits from. The uses that would retain members not named
/// anywhere (initializers, subscripts, `callAsFunction`, conformance witnesses) are only collected from the clauses
/// that no configuration compiles with certainty, whatever `narrowsNestedBlocks`: every enclosing block is evaluated,
/// and `canImport()` is answered for the system modules the platform settles. A clause that may be compiled, such as
/// the `#else` of an `#if os(Windows)` nested in another block, or a `canImport()` clause of an unknown module, is
/// described by the index store.
public final class PlatformConditionalNameCollector: PeripherySyntaxNodeVisitor {
    private static let platformConditions: Set<String> = ["os", "targetEnvironment", "arch", "canImport"]

    private static let evaluableConditions: Set<String> = ["os", "arch", "targetEnvironment"]

    /// A line that names an identifier inside a platform conditional clause, and the clause's condition.
    public struct Site: Hashable {
        public let line: Int
        public let condition: String
    }

    public private(set) var collected = PlatformConditionalNames()
    /// The names written as references in the platform conditional clauses.
    public var names: Set<String> {
        collected.references
    }

    /// The sites of each name, only collected when a location converter is given (for `--explain`).
    public private(set) var sites: [String: [Site]] = [:]
    /// The sites of each initializer call that writes no initializer name, likewise.
    public private(set) var constructionSites: [PlatformConditionalConstruction: [Site]] = [:]
    /// The clauses whose names were collected.
    private(set) var clauses: [IfConfigClauseSyntax] = []

    private let configurations: [PlatformBuildConfiguration]
    private let narrowsNestedBlocks: Bool
    private let collectsEveryBlock: Bool
    private let locationConverter: SourceLocationConverter?
    /// The block whose clauses were all collected: the blocks it contains are not visited.
    private var collectedBlock: SyntaxIdentifier?
    /// The clauses no configuration compiles whose unnamed uses were collected, nested blocks included.
    private var unnamedUseClauses: Set<SyntaxIdentifier> = []

    /// - Parameter configurations: the configurations the file was compiled for. When empty, every clause of every
    ///   platform conditional block is collected.
    /// - Parameter narrowsNestedBlocks: whether the blocks nested in another `#if` block are narrowed too, instead of
    ///   being collected whole.
    /// - Parameter locationConverter: when given, the line and condition of each name are collected too.
    /// - Parameter collectsEveryBlock: whether every `#if` block is collected, not only the platform conditional ones.
    public init(
        configurations: [PlatformBuildConfiguration] = [],
        narrowsNestedBlocks: Bool = false,
        locationConverter: SourceLocationConverter? = nil,
        collectsEveryBlock: Bool = false
    ) {
        self.configurations = configurations
        self.narrowsNestedBlocks = narrowsNestedBlocks
        self.collectsEveryBlock = collectsEveryBlock
        self.locationConverter = locationConverter
    }

    static func collect(
        from syntax: SourceFileSyntax,
        configurations: [PlatformBuildConfiguration] = [],
        narrowsNestedBlocks: Bool = false
    ) -> Set<String> {
        let collector = PlatformConditionalNameCollector(configurations: configurations, narrowsNestedBlocks: narrowsNestedBlocks)
        collector.walk(syntax)
        return collector.names
    }

    static func collectAll(from syntax: SourceFileSyntax, configurations: [PlatformBuildConfiguration] = []) -> PlatformConditionalNames {
        let collector = PlatformConditionalNameCollector(configurations: configurations)
        collector.walk(syntax)
        return collector.collected
    }

    /// The clauses of every `#if` block, platform conditional or not, that none of the configurations may have
    /// compiled: a block that cannot be narrowed to the clauses no configuration compiled is returned whole.
    public static func uncompiledClauses(
        from syntax: SourceFileSyntax,
        configurations: [PlatformBuildConfiguration]
    ) -> [IfConfigClauseSyntax] {
        let collector = PlatformConditionalNameCollector(configurations: configurations, collectsEveryBlock: true)
        collector.walk(syntax)
        return collector.clauses
    }

    public func visit(_ node: IfConfigDeclSyntax) {
        collectUnnamedUses(in: node)
        collectOperatorUses(in: node)

        guard collectedBlock == nil else { return }
        guard collectsEveryBlock || node.clauses.contains(where: { isPlatformCondition($0.condition) }) else {
            // The platform conditional blocks it contains are still visited.
            node.clauses.forEach(collectOtherClauseNames(in:))
            return
        }

        if let uncompiledClauses = uncompiledClauses(of: node) {
            uncompiledClauses.forEach(collectNames(in:))
            // Blocks nested in a compiled clause are visited: collected whole as they are nested, or narrowed with
            // `narrowsNestedBlocks`.
            return
        }

        // The `#else` clause has no condition of its own, so the whole block is collected.
        node.clauses.forEach(collectNames(in:))
        collectedBlock = node.id
    }

    public func visitPost(_ node: IfConfigDeclSyntax) {
        if node.id == collectedBlock {
            collectedBlock = nil
        }
    }

    // MARK: - Private

    private func collectNames(in clause: IfConfigClauseSyntax) {
        guard let elements = clause.elements else { return }

        clauses.append(clause)
        let receiverReader = PlatformConditionalReceiverReader(clause: clause)
        for token in elements.tokens(viewMode: .sourceAccurate) {
            if let name = referencedName(token) {
                collected.references.insert(name)
                if let use = receiverReader.memberUse(of: token, named: name) {
                    collected.memberUses.insert(use)
                } else {
                    collected.unscopedReferences.insert(name)
                }

                if let locationConverter {
                    sites[name, default: []].append(site(of: token, in: clause, converter: locationConverter))
                }
            }
        }

        let declarationCollector = UnnamedUseCollector(viewMode: .sourceAccurate)
        declarationCollector.walk(elements)
        collected.overriddenNames.formUnion(declarationCollector.overriddenNames)
        collected.inheritedNames.formUnion(declarationCollector.inheritedNames)
        collected.conformingExtendedNames.formUnion(declarationCollector.conformances.map(\.typeName))
        collected.declaredTypeNames.formUnion(declarationCollector.declaredTypeNames)
    }

    private func site(of node: some SyntaxProtocol, in clause: IfConfigClauseSyntax, converter: SourceLocationConverter) -> Site {
        let condition = clause.condition.map { "\(clause.poundKeyword.text) \($0.trimmedDescription)" } ?? clause.poundKeyword.text
        return Site(line: node.startLocation(converter: converter).line, condition: condition)
    }

    /// For each operator applied in a clause of a platform conditional block that no configuration compiles with
    /// certainty, the names written in that clause. A clause a configuration compiles, such as `#if canImport(Dispatch)`
    /// on Apple platforms, is in the index store, which resolves its operators. The blocks it contains are visited on
    /// their own.
    private func collectOperatorUses(in node: IfConfigDeclSyntax) {
        guard collectsEveryBlock || node.clauses.contains(where: { isPlatformCondition($0.condition) }) else { return }

        let enclosingClauses = enclosingClauses(of: node)
        let activeClausesByConfiguration = activeClausesByConfiguration(of: [node] + enclosingClauses.map(\.block))

        for clause in node.clauses {
            guard let elements = clause.elements else { continue }

            let isCompiled = activeClausesByConfiguration.contains { activeClauses in
                zip(activeClauses, [clause] + enclosingClauses.map(\.clause)).allSatisfy { activeClause, clause in
                    guard case let .some(activeID) = activeClause else { return false }

                    return activeID == clause.id
                }
            }
            guard !isCompiled else { continue }

            var names: Set<String> = []
            var operators: Set<String> = []
            for token in elements.tokens(viewMode: .sourceAccurate) {
                guard let name = referencedName(token) else { continue }

                names.insert(name)
                if !token.tokenKind.isIdentifier {
                    operators.insert(name)
                }
            }
            for name in operators {
                collected.operatorClauseNames[name, default: []].formUnion(names)
            }
        }
    }

    /// For each configuration, the clause it compiles of each block, as `provenActiveClause` tells.
    private func activeClausesByConfiguration(of blocks: [IfConfigDeclSyntax]) -> [[SyntaxIdentifier??]] {
        configurations.map { configuration in
            blocks.map { provenActiveClause(of: $0, in: configuration.answeringCanImport) }
        }
    }

    /// Collects the unnamed uses of the clauses of the block that no configuration compiles, unless an enclosing
    /// clause already accounts for them.
    private func collectUnnamedUses(in node: IfConfigDeclSyntax) {
        guard !configurations.isEmpty else { return }

        let enclosingClauses = enclosingClauses(of: node)
        guard !enclosingClauses.contains(where: { unnamedUseClauses.contains($0.clause.id) }) else { return }

        let activeClausesByConfiguration = activeClausesByConfiguration(of: [node] + enclosingClauses.map(\.block))
        // A configuration that compiles another clause of an enclosing block compiles none of this block.
        let excludesBlock = activeClausesByConfiguration.map { activeClauses in
            zip(activeClauses.dropFirst(), enclosingClauses).contains { activeClause, enclosing in
                guard case let .some(activeID) = activeClause else { return false }

                return activeID != enclosing.clause.id
            }
        }

        for clause in node.clauses {
            let isUncompiled = zip(activeClausesByConfiguration, excludesBlock).allSatisfy { activeClauses, excludesBlock in
                guard !excludesBlock else { return true }
                guard case let .some(activeID) = activeClauses[0] else { return false }

                return activeID != clause.id
            }
            guard isUncompiled, let elements = clause.elements else { continue }

            unnamedUseClauses.insert(clause.id)
            collectUnnamedUses(in: elements, of: clause)
        }
    }

    private func collectUnnamedUses(in elements: IfConfigClauseSyntax.Elements, of clause: IfConfigClauseSyntax) {
        var names: Set<String> = []
        for token in elements.tokens(viewMode: .sourceAccurate) {
            if let name = referencedName(token) {
                names.insert(name)
            }
        }

        let useCollector = UnnamedUseCollector(viewMode: .sourceAccurate)
        useCollector.walk(elements)
        collected.conformances.formUnion(useCollector.conformances)
        for (construction, node) in useCollector.constructions(namedIn: names) {
            collected.constructions.insert(construction)
            if let locationConverter {
                constructionSites[construction, default: []].append(site(of: node, in: clause, converter: locationConverter))
            }
        }
        if useCollector.accessesSubscript {
            collected.subscriptedNames.formUnion(names)
        }
        if useCollector.callsValue {
            collected.valueCalledNames.formUnion(names)
        }
    }

    /// The identifier of the clause the configuration compiles, `.some(nil)` when it compiles none, or `nil` when it
    /// cannot be known.
    private func provenActiveClause(of node: IfConfigDeclSyntax, in configuration: PlatformBuildConfiguration) -> SyntaxIdentifier?? {
        guard node.clauses.allSatisfy({ $0.condition.map { isEvaluable($0, allowingCanImport: true) } ?? true }),
              let clause = activeClause(of: node, in: configuration)
        else { return nil }

        return .some(clause?.id)
    }

    private func collectOtherClauseNames(in clause: IfConfigClauseSyntax) {
        guard let elements = clause.elements else { return }

        for token in elements.tokens(viewMode: .sourceAccurate) {
            if let name = referencedName(token) {
                collected.otherClauseNames.insert(name)
            }
        }
    }

    /// The name the token refers to: an identifier that is a reference, or an applied operator.
    private func referencedName(_ token: TokenSyntax) -> String? {
        switch token.tokenKind {
        case .identifier:
            guard isReference(token) else { return nil }

            return token.identifier?.name ?? token.text
        case .binaryOperator, .prefixOperator, .postfixOperator:
            guard let parent = token.parent,
                  parent.is(BinaryOperatorExprSyntax.self)
                  || parent.is(PrefixOperatorExprSyntax.self)
                  || parent.is(PostfixOperatorExprSyntax.self)
                  || parent.is(DeclReferenceExprSyntax.self)
            else { return nil }

            return token.text
        default:
            return nil
        }
    }

    /// Returns the clauses that none of the configurations compiled, or `nil` when they cannot be known with
    /// certainty.
    private func uncompiledClauses(of node: IfConfigDeclSyntax) -> [IfConfigClauseSyntax]? {
        let enclosingClauses = enclosingClauses(of: node)

        guard !configurations.isEmpty,
              enclosingClauses.isEmpty || narrowsNestedBlocks,
              isEvaluable(node, allowingCanImport: true),
              enclosingClauses.allSatisfy({ isEvaluable($0.block, allowingCanImport: true) })
        else { return nil }

        var compiledClauses: Set<SyntaxIdentifier> = []

        // `canImport()` is answered for the system modules the platform settles and the project's modules the build
        // compiled; any other module leaves the block whole.
        for configuration in configurations.map(\.answeringCanImport) {
            guard let clause = activeClause(of: node, in: configuration) else { return nil }

            var compilesEnclosingClauses = true
            for (block, enclosingClause) in enclosingClauses {
                guard let activeClause = activeClause(of: block, in: configuration) else { return nil }

                if activeClause?.id != enclosingClause.id {
                    compilesEnclosingClauses = false
                }
            }

            if compilesEnclosingClauses, let clause {
                compiledClauses.insert(clause.id)
            }
        }

        return node.clauses.filter { !compiledClauses.contains($0.id) }
    }

    /// The clause the configuration compiles, `.some(nil)` when it compiles none, or `nil` when it cannot be known.
    /// When the configuration answers `canImport()`, a module whose presence is not known only leaves the clause
    /// unknown when it decides it: `canImport(App_iOS) || canImport(App_macOS)` is compiled by the build of `App_macOS`.
    private func activeClause(of node: IfConfigDeclSyntax, in configuration: PlatformBuildConfiguration) -> IfConfigClauseSyntax?? {
        guard configuration.answersCanImport else { return evaluatedClause(of: node, in: configuration) }
        guard let clause = evaluatedClause(of: node, in: configuration.assumingUnknownModules(importable: true)),
              let otherClause = evaluatedClause(of: node, in: configuration.assumingUnknownModules(importable: false)),
              clause?.id == otherClause?.id
        else { return nil }

        return clause
    }

    private func evaluatedClause(of node: IfConfigDeclSyntax, in configuration: PlatformBuildConfiguration) -> IfConfigClauseSyntax?? {
        let (clause, diagnostics) = node.activeClause(in: configuration)
        guard diagnostics.isEmpty else { return nil }

        return .some(clause)
    }

    private func isEvaluable(_ node: IfConfigDeclSyntax, allowingCanImport: Bool = false) -> Bool {
        node.clauses.allSatisfy { $0.condition.map { isEvaluable($0, allowingCanImport: allowingCanImport) } ?? true }
    }

    /// The `#if` blocks the node is nested in, from the innermost, with the clause of each that contains it.
    private func enclosingClauses(of node: IfConfigDeclSyntax) -> [(block: IfConfigDeclSyntax, clause: IfConfigClauseSyntax)] {
        var result: [(block: IfConfigDeclSyntax, clause: IfConfigClauseSyntax)] = []
        var parent = node.parent

        while let current = parent {
            if let clause = current.as(IfConfigClauseSyntax.self), let block = clause.parent?.parent?.as(IfConfigDeclSyntax.self) {
                result.append((block, clause))
            }
            parent = current.parent
        }

        return result
    }

    /// Returns `true` when the condition only combines `os()`, `arch()` and `targetEnvironment()` checks with `!`,
    /// `&&`, `||` and parentheses, and `canImport()` checks of a single module with `allowingCanImport`.
    private func isEvaluable(_ condition: ExprSyntax, allowingCanImport: Bool = false) -> Bool {
        if let tuple = condition.as(TupleExprSyntax.self) {
            guard tuple.elements.count == 1, let element = tuple.elements.first, element.label == nil else {
                return false
            }

            return isEvaluable(element.expression, allowingCanImport: allowingCanImport)
        }

        if let prefix = condition.as(PrefixOperatorExprSyntax.self) {
            return prefix.operator.text == "!" && isEvaluable(prefix.expression, allowingCanImport: allowingCanImport)
        }

        if let sequence = condition.as(SequenceExprSyntax.self) {
            return sequence.elements.enumerated().allSatisfy { index, element in
                if index.isMultiple(of: 2) {
                    return isEvaluable(element, allowingCanImport: allowingCanImport)
                }

                guard let binaryOperator = element.as(BinaryOperatorExprSyntax.self) else { return false }

                return ["&&", "||"].contains(binaryOperator.operator.text)
            }
        }

        if let call = condition.as(FunctionCallExprSyntax.self) {
            guard let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
                  callee.argumentNames == nil,
                  Self.evaluableConditions.contains(callee.baseName.text)
                  || (allowingCanImport && callee.baseName.text == "canImport"),
                  call.trailingClosure == nil,
                  call.additionalTrailingClosures.isEmpty,
                  call.arguments.count == 1,
                  let argument = call.arguments.first,
                  argument.label == nil,
                  let name = argument.expression.as(DeclReferenceExprSyntax.self)
            else { return false }

            return name.argumentNames == nil
        }

        return false
    }

    /// Returns `true` when the token is the name in a `DeclReferenceExprSyntax`, `IdentifierTypeSyntax`,
    /// `MemberTypeSyntax`, `MacroExpansionExprSyntax` or `MacroExpansionDeclSyntax`.
    /// Declaration names, parameter names, argument labels and the type extended by an `extension` do not refer to a
    /// declaration: writing them in a conditional block must not retain it.
    private func isReference(_ token: TokenSyntax) -> Bool {
        guard let parent = token.parent else { return false }

        if let extensionDeclaration = parent.parent?.as(ExtensionDeclSyntax.self),
           extensionDeclaration.extendedType.id == parent.id
        {
            return false
        }

        return parent.is(DeclReferenceExprSyntax.self)
            || parent.is(IdentifierTypeSyntax.self)
            || parent.is(MemberTypeSyntax.self)
            || parent.is(MacroExpansionExprSyntax.self)
            || parent.is(MacroExpansionDeclSyntax.self)
    }

    private func isPlatformCondition(_ condition: ExprSyntax?) -> Bool {
        guard let condition else { return false }

        return condition.tokens(viewMode: .sourceAccurate).contains {
            if case .identifier = $0.tokenKind {
                Self.platformConditions.contains($0.text)
            } else {
                false
            }
        }
    }
}

/// Collects what the code of a clause uses without writing a name: the conformances of its extensions, the members
/// it overrides, the types its classes and protocols inherit from, the initializers it calls, and whether it accesses
/// a subscript or calls a value.
private final class UnnamedUseCollector: SyntaxVisitor {
    private(set) var conformances: Set<PlatformConditionalConformance> = []
    private(set) var overriddenNames: Set<String> = []
    private(set) var inheritedNames: Set<String> = []
    /// The names of the types and type aliases the clause declares.
    private(set) var declaredTypeNames: Set<String> = []
    private(set) var accessesSubscript = false
    /// The initializer calls, with the first expression that makes each.
    private var typedConstructions: [PlatformConditionalConstruction: Syntax] = [:]
    /// The labels of the `.init(...)` calls whose type the syntax does not tell, with the first call of each.
    private var untypedConstructionLabels: [[String]: Syntax] = [:]
    /// The names called directly, `name()`, which call a value when the clause binds them.
    private var calledNames: Set<String> = []
    private var boundNames: Set<String> = []
    private var callsComplexValue = false

    /// Whether the clause calls a value: a name it binds (`let value = T(); value()`), `$0()`, `value?()` or the
    /// result of a call or subscript.
    var callsValue: Bool {
        callsComplexValue || !calledNames.isDisjoint(with: boundNames)
    }

    /// The initializer calls, those of untyped `.init(...)` ascribed to every name written in the clause, with the
    /// expression that makes each.
    func constructions(namedIn names: Set<String>) -> [PlatformConditionalConstruction: Syntax] {
        var result = typedConstructions
        for (labels, node) in untypedConstructionLabels {
            for name in names {
                let construction = PlatformConditionalConstruction(typeName: name, labels: labels)
                if result[construction] == nil {
                    result[construction] = node
                }
            }
        }
        return result
    }

    private func insert(_ typeName: String, labels: [String]?, at node: some SyntaxProtocol) {
        let construction = PlatformConditionalConstruction(typeName: typeName, labels: labels)
        if typedConstructions[construction] == nil {
            typedConstructions[construction] = Syntax(node)
        }
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let labels = Self.labels(of: node)
        let callee = node.calledExpression

        if let member = callee.as(MemberAccessExprSyntax.self), Self.isInit(member.declName) {
            if let base = member.base {
                if let typeName = Self.typeName(of: base) {
                    insert(typeName, labels: labels, at: node)
                }
            } else if let contextTypeNames = Self.contextTypeNames(of: node) {
                for typeName in contextTypeNames {
                    insert(typeName, labels: labels, at: node)
                }
            } else {
                if untypedConstructionLabels[labels] == nil {
                    untypedConstructionLabels[labels] = Syntax(node)
                }
            }
        } else if let typeName = Self.typeName(of: callee) {
            // A function or method call is recorded too: it only matches a type of the same name.
            insert(typeName, labels: labels, at: node)
        }

        if let reference = callee.as(DeclReferenceExprSyntax.self) {
            if case .dollarIdentifier = reference.baseName.tokenKind {
                callsComplexValue = true
            } else {
                calledNames.insert(reference.baseName.identifier?.name ?? reference.baseName.text)
            }
        } else if callee.is(FunctionCallExprSyntax.self) || callee.is(SubscriptCallExprSyntax.self)
            || callee.is(OptionalChainingExprSyntax.self) || callee.is(ForceUnwrapExprSyntax.self)
            || callee.is(TupleExprSyntax.self)
        {
            callsComplexValue = true
        }

        return .visitChildren
    }

    /// `T.init` unapplied, `T.init(value:)`, and `T.self`, which a generic function may construct.
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        guard let base = node.base, let typeName = Self.typeName(of: base) else { return .visitChildren }

        if node.declName.baseName.tokenKind == .keyword(.self) {
            insert(typeName, labels: nil, at: node)
        } else if Self.isInit(node.declName),
                  node.parent?.as(FunctionCallExprSyntax.self)?.calledExpression.id != node.id
        {
            let labels = node.declName.argumentNames.map { $0.arguments.map(\.name.text) }
            insert(typeName, labels: labels, at: node)
        }
        return .visitChildren
    }

    override func visit(_: SubscriptCallExprSyntax) -> SyntaxVisitorContinueKind {
        accessesSubscript = true
        return .visitChildren
    }

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        boundNames.insert(node.identifier.identifier?.name ?? node.identifier.text)
        return .visitChildren
    }

    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        let name = node.secondName ?? node.firstName
        boundNames.insert(name.identifier?.name ?? name.text)
        return .visitChildren
    }

    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        let name = node.secondName ?? node.firstName
        boundNames.insert(name.identifier?.name ?? name.text)
        return .visitChildren
    }

    override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
        boundNames.insert(node.name.identifier?.name ?? node.name.text)
        return .visitChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        if let typeName = Self.typeNames(of: node.extendedType).first {
            for protocolName in Self.inheritedTypeNames(of: node.inheritanceClause) {
                conformances.insert(PlatformConditionalConformance(typeName: typeName, protocolName: protocolName))
            }
        }
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        insertInheritedNames(of: node.inheritanceClause)
        insertDeclaredTypeName(node.name)
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        insertInheritedNames(of: node.inheritanceClause)
        insertDeclaredTypeName(node.name)
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        insertDeclaredTypeName(node.name)
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        insertDeclaredTypeName(node.name)
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        insertDeclaredTypeName(node.name)
        return .visitChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        insertDeclaredTypeName(node.name)
        return .visitChildren
    }

    private func insertDeclaredTypeName(_ name: TokenSyntax) {
        declaredTypeNames.insert(name.identifier?.name ?? name.text)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if Self.isOverride(node.modifiers) {
            overriddenNames.insert(node.name.identifier?.name ?? node.name.text)
        }
        return .visitChildren
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        if Self.isOverride(node.modifiers) {
            overriddenNames.insert("subscript")
        }
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        if Self.isOverride(node.modifiers) {
            for binding in node.bindings {
                for token in binding.pattern.tokens(viewMode: .sourceAccurate) where token.tokenKind.isIdentifier {
                    overriddenNames.insert(token.identifier?.name ?? token.text)
                }
            }
        }
        return .visitChildren
    }

    private func insertInheritedNames(of clause: InheritanceClauseSyntax?) {
        for name in Self.inheritedTypeNames(of: clause) {
            inheritedNames.insert(name)
        }
    }

    private static func isInit(_ name: DeclReferenceExprSyntax) -> Bool {
        name.baseName.tokenKind == .keyword(.`init`)
    }

    /// The argument labels of the call, `_` for an unlabeled argument, without its trailing closures, whose labels the
    /// syntax does not tell.
    private static func labels(of call: FunctionCallExprSyntax) -> [String] {
        call.arguments.map { $0.label?.text ?? "_" }
    }

    /// The name of the type an expression may refer to: `T`, `Module.T`, `T<Int>`.
    private static func typeName(of expression: ExprSyntax) -> String? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            guard case .identifier = reference.baseName.tokenKind else { return nil }

            return reference.baseName.identifier?.name ?? reference.baseName.text
        }
        if let member = expression.as(MemberAccessExprSyntax.self), member.base != nil {
            guard case .identifier = member.declName.baseName.tokenKind else { return nil }

            return member.declName.baseName.identifier?.name ?? member.declName.baseName.text
        }
        if let specialization = expression.as(GenericSpecializationExprSyntax.self) {
            return typeName(of: specialization.expression)
        }
        if let typeExpression = expression.as(TypeExprSyntax.self) {
            return typeNames(of: typeExpression.type).first
        }
        return nil
    }

    /// The type a `.init(...)` call constructs when the syntax tells it: the annotated type of the variable or the
    /// parameter it initializes, optional or not.
    private static func contextTypeNames(of call: FunctionCallExprSyntax) -> [String]? {
        var node = Syntax(call)
        while let parent = node.parent, parent.is(TryExprSyntax.self) || parent.is(AwaitExprSyntax.self) {
            node = parent
        }
        guard let initializer = node.parent?.as(InitializerClauseSyntax.self) else { return nil }

        let type: TypeSyntax? = if let binding = initializer.parent?.as(PatternBindingSyntax.self) {
            binding.typeAnnotation?.type
        } else {
            initializer.parent?.as(FunctionParameterSyntax.self)?.type
        }
        guard let type else { return nil }

        let names = typeNames(of: type)
        return names.isEmpty ? nil : names
    }

    private static func isOverride(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.tokenKind == .keyword(.override) }
    }

    private static func inheritedTypeNames(of clause: InheritanceClauseSyntax?) -> [String] {
        clause?.inheritedTypes.flatMap { typeNames(of: $0.type) } ?? []
    }

    /// The names of the types, without their module or enclosing types.
    private static func typeNames(of type: TypeSyntax) -> [String] {
        if let identifier = type.as(IdentifierTypeSyntax.self) {
            return [identifier.name.identifier?.name ?? identifier.name.text]
        }
        if let member = type.as(MemberTypeSyntax.self) {
            return [member.name.identifier?.name ?? member.name.text]
        }
        if let attributed = type.as(AttributedTypeSyntax.self) {
            return typeNames(of: attributed.baseType)
        }
        if let composition = type.as(CompositionTypeSyntax.self) {
            return composition.elements.flatMap { typeNames(of: $0.type) }
        }
        if let optional = type.as(OptionalTypeSyntax.self) {
            return typeNames(of: optional.wrappedType)
        }
        if let optional = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            return typeNames(of: optional.wrappedType)
        }
        return []
    }
}

private extension TokenKind {
    var isIdentifier: Bool {
        if case .identifier = self {
            true
        } else {
            false
        }
    }
}
