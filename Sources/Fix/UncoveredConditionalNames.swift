import Foundation
import SourceGraph
import SwiftParser
import SwiftSyntax
import SyntaxAnalysis
import SystemPackage

/// What the `#if` clauses that no scanned build compiled may use, so that `fix --rule unused` keeps it.
///
/// The index only holds the references of the compiled clauses. The scan retains the names of the platform clauses
/// it did not compile, but not those of other conditions: a call made only under `#if !DEBUG`, a custom flag,
/// `swift()` or `compiler()` looks unused to a debug scan. Every block is read here, over every indexed file: a block
/// that only checks `os()`, `arch()` and `targetEnvironment()` is narrowed to the clauses no indexed build of its file
/// compiled, any other block is taken whole.
///
/// The clauses are read broadly rather than resolved: every identifier counts, whether it refers to a declaration,
/// declares one or names a parameter, since a declaration in such a clause can override, implement or extend one.
public struct UncoveredConditionalNames {
    /// Every identifier and operator written in the clauses.
    public let names: Set<String>
    /// The types declared, extended, inherited from, constrained to or used as an attribute in the clauses, and the
    /// types of the scan they inherit from: code in the clauses can reach any of their members without naming it,
    /// through a conformance or an override.
    public let typeNames: Set<String>
    /// Whether some clause holds code, which can call a subscript, `callAsFunction`, an operator, a pattern match
    /// (`~=`), a string interpolation or a dynamic member without writing its name.
    public let hasCode: Bool

    public init(names: Set<String>, typeNames: Set<String> = [], hasCode: Bool = false) {
        self.names = names
        self.typeNames = typeNames
        self.hasCode = hasCode
    }

    public init(graph: SourceGraph) throws {
        var collected = UncoveredConditionalNames(names: [])
        for file in graph.indexedSourceFiles {
            let source = try String(contentsOfFile: file.path.string, encoding: .utf8)
            collected = collected.merging(Self.read(source, variants: file.variants))
        }
        self.init(names: collected.names, typeNames: Self.withSupertypes(collected.typeNames, in: graph), hasCode: collected.hasCode)
    }

    /// The name of the declaration, or of one of its members, written in a clause.
    func writtenName(of declaration: Declaration) -> String? {
        ([declaration] + declaration.descendentDeclarations)
            .filter { !$0.isImplicit }
            .map { Self.baseName(of: $0.name) }
            .first(where: names.contains)
    }

    /// The enclosing type, or extension, whose members the clauses can reach without naming them.
    func reachingType(of declaration: Declaration) -> String? {
        var current = declaration.parent
        while let decl = current {
            let name = Self.baseName(of: decl.name)
            if typeNames.contains(name) {
                return name
            }
            current = decl.parent
        }
        return nil
    }

    /// Whether the clauses may use the declaration without writing its name: a subscript, an operator,
    /// `callAsFunction`, `appendInterpolation` or `dynamicallyCall`.
    func mayUseImplicitly(_ declaration: Declaration) -> Bool {
        guard hasCode else { return false }

        let name = Self.baseName(of: declaration.name)
        let isOperator = name.first.map { !$0.isLetter && !$0.isNumber && $0 != "_" } ?? false
        return declaration.kind == .functionSubscript
            || isOperator
            || name == "callAsFunction"
            || name.hasPrefix("appendInterpolation")
            || name.hasPrefix("dynamicallyCall")
    }

    static func read(_ source: String, variants: Set<IndexVariant>) -> UncoveredConditionalNames {
        let configurations = variants.map { PlatformBuildConfiguration(triple: $0.triple) }
        let clauses = PlatformConditionalNameCollector.uncompiledClauses(
            from: Parser.parse(source: source),
            configurations: configurations.contains(nil) ? [] : configurations.compactMap(\.self)
        )

        var names: Set<String> = []
        var typeNames: Set<String> = []
        var hasCode = false
        for clause in clauses {
            guard let elements = clause.elements else { continue }

            for token in elements.tokens(viewMode: .sourceAccurate) {
                hasCode = true
                guard let name = writtenName(of: token) else { continue }

                names.insert(name)
                if namesAType(token) {
                    typeNames.insert(name)
                }
            }
        }
        return UncoveredConditionalNames(names: names, typeNames: typeNames, hasCode: hasCode)
    }

    // MARK: - Private

    private func merging(_ other: UncoveredConditionalNames) -> UncoveredConditionalNames {
        UncoveredConditionalNames(
            names: names.union(other.names),
            typeNames: typeNames.union(other.typeNames),
            hasCode: hasCode || other.hasCode
        )
    }

    private static func writtenName(of token: TokenSyntax) -> String? {
        switch token.tokenKind {
        case .identifier:
            token.identifier?.name ?? token.text
        case .binaryOperator, .prefixOperator, .postfixOperator:
            token.text
        default:
            nil
        }
    }

    /// Whether the token names a type the code can reach the members of: the name of a type declaration, or a name
    /// in an extended type, an inheritance clause, a generic constraint or an attribute.
    private static func namesAType(_ token: TokenSyntax) -> Bool {
        if let parent = token.parent, parent.isProtocol(DeclGroupSyntax.self),
           parent.asProtocol(NamedDeclSyntax.self)?.name.id == token.id
        {
            return true
        }

        var current = token.parent
        while let node = current {
            if node.is(InheritanceClauseSyntax.self) || node.is(GenericWhereClauseSyntax.self)
                || node.is(GenericParameterClauseSyntax.self) || node.is(AttributeSyntax.self)
            {
                return true
            }
            if let parent = node.parent?.as(ExtensionDeclSyntax.self), parent.extendedType.id == node.id {
                return true
            }
            if node.is(IfConfigClauseSyntax.self) {
                return false
            }
            current = node.parent
        }
        return false
    }

    /// The names with those of the classes and protocols of the scan that the named types inherit from, transitively.
    private static func withSupertypes(_ names: Set<String>, in graph: SourceGraph) -> Set<String> {
        let kinds: Set<Declaration.Kind> = [
            .class, .struct, .enum, .protocol, .extensionClass, .extensionStruct, .extensionEnum, .extensionProtocol,
        ]
        var pending = Array(graph.declarations(ofKinds: kinds).filter { names.contains(baseName(of: $0.name)) })
        var visited: Set<Declaration> = []
        var result = names

        while let current = pending.popLast() {
            guard visited.insert(current).inserted else { continue }

            result.insert(baseName(of: current.name))
            for reference in current.related where [.class, .protocol].contains(reference.declarationKind) {
                if let inherited = graph.declaration(withUsr: reference.usr) {
                    pending.append(inherited)
                }
            }
        }
        return result
    }

    private static func baseName(of declarationName: String) -> String {
        declarationName.prefix { $0 != "(" }.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
    }
}
