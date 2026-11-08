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
/// of `os()`, `arch()` and `targetEnvironment()` checks joined by `!`, `&&` and `||`, when it is not nested in another
/// `#if` block, and when every configuration evaluates it without a diagnostic. Otherwise the whole block is collected.
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
/// its name: the conformances its extensions declare, the members it overrides and the types it inherits from.
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
    /// The clauses whose names were collected.
    private(set) var clauses: [IfConfigClauseSyntax] = []

    private let configurations: [PlatformBuildConfiguration]
    private let narrowsNestedBlocks: Bool
    private let collectsEveryBlock: Bool
    private let locationConverter: SourceLocationConverter?
    /// The block whose clauses were all collected: the blocks it contains are not visited.
    private var collectedBlock: SyntaxIdentifier?

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
        for token in elements.tokens(viewMode: .sourceAccurate) {
            if let name = referencedName(token) {
                collected.references.insert(name)

                if let locationConverter {
                    let condition = clause.condition.map { "\(clause.poundKeyword.text) \($0.trimmedDescription)" } ?? clause.poundKeyword.text
                    let line = token.startLocation(converter: locationConverter).line
                    sites[name, default: []].append(Site(line: line, condition: condition))
                }
            }
        }

        let declarationCollector = UnnamedUseCollector(viewMode: .sourceAccurate)
        declarationCollector.walk(elements)
        collected.conformances.formUnion(declarationCollector.conformances)
        collected.overriddenNames.formUnion(declarationCollector.overriddenNames)
        collected.inheritedNames.formUnion(declarationCollector.inheritedNames)
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
              isEvaluable(node),
              enclosingClauses.allSatisfy({ isEvaluable($0.block) })
        else { return nil }

        var compiledClauses: Set<SyntaxIdentifier> = []

        for configuration in configurations {
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
    private func activeClause(of node: IfConfigDeclSyntax, in configuration: PlatformBuildConfiguration) -> IfConfigClauseSyntax?? {
        let (clause, diagnostics) = node.activeClause(in: configuration)
        guard diagnostics.isEmpty else { return nil }

        return .some(clause)
    }

    private func isEvaluable(_ node: IfConfigDeclSyntax) -> Bool {
        node.clauses.allSatisfy { $0.condition.map(isEvaluable) ?? true }
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
    /// `&&`, `||` and parentheses.
    private func isEvaluable(_ condition: ExprSyntax) -> Bool {
        if let tuple = condition.as(TupleExprSyntax.self) {
            guard tuple.elements.count == 1, let element = tuple.elements.first, element.label == nil else {
                return false
            }

            return isEvaluable(element.expression)
        }

        if let prefix = condition.as(PrefixOperatorExprSyntax.self) {
            return prefix.operator.text == "!" && isEvaluable(prefix.expression)
        }

        if let sequence = condition.as(SequenceExprSyntax.self) {
            return sequence.elements.enumerated().allSatisfy { index, element in
                if index.isMultiple(of: 2) {
                    return isEvaluable(element)
                }

                guard let binaryOperator = element.as(BinaryOperatorExprSyntax.self) else { return false }

                return ["&&", "||"].contains(binaryOperator.operator.text)
            }
        }

        if let call = condition.as(FunctionCallExprSyntax.self) {
            guard let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
                  callee.argumentNames == nil,
                  Self.evaluableConditions.contains(callee.baseName.text),
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

/// Collects what the declarations of a clause use without writing a name: the conformances of its extensions, the
/// members it overrides and the types its classes and protocols inherit from.
private final class UnnamedUseCollector: SyntaxVisitor {
    private(set) var conformances: Set<PlatformConditionalConformance> = []
    private(set) var overriddenNames: Set<String> = []
    private(set) var inheritedNames: Set<String> = []

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
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        insertInheritedNames(of: node.inheritanceClause)
        return .visitChildren
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
