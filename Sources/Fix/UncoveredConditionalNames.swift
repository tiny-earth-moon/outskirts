import Foundation
import SourceGraph
import SwiftParser
import SyntaxAnalysis
import SystemPackage

/// The names written in the `#if` clauses that no scanned build compiled, so that `fix --rule unused` keeps the
/// declarations they may reference.
///
/// The index only holds the references of the compiled clauses. The scan retains the names of the platform clauses
/// it did not compile, but not those of other conditions: a call made only under `#if !DEBUG`, a custom flag,
/// `swift()` or `compiler()` looks unused to a debug scan. Every block is read here, over every indexed file: a block
/// that only checks `os()`, `arch()` and `targetEnvironment()` is narrowed to the clauses no indexed build of its file
/// compiled, any other block is taken whole.
public struct UncoveredConditionalNames {
    public let names: Set<String>

    public init(names: Set<String>) {
        self.names = names
    }

    public init(graph: SourceGraph) throws {
        var names: Set<String> = []
        for file in graph.indexedSourceFiles {
            let source = try String(contentsOfFile: file.path.string, encoding: .utf8)
            names.formUnion(Self.names(in: source, variants: file.variants))
        }
        self.names = names
    }

    /// The names of the declaration that a clause no scanned build compiled may reference: its own, or one of its
    /// members', so that a removed type does not take a member referenced there with it.
    func writtenName(of declaration: Declaration) -> String? {
        ([declaration] + declaration.descendentDeclarations)
            .filter { !$0.isImplicit }
            .map { Self.baseName(of: $0.name) }
            .first(where: names.contains)
    }

    static func names(in source: String, variants: Set<IndexVariant>) -> Set<String> {
        let configurations = variants.map { PlatformBuildConfiguration(triple: $0.triple) }
        return PlatformConditionalNameCollector.collect(
            from: Parser.parse(source: source),
            configurations: configurations.contains(nil) ? [] : configurations.compactMap(\.self),
            collectsEveryBlock: true
        )
    }

    private static func baseName(of declarationName: String) -> String {
        declarationName.prefix { $0 != "(" }.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
    }
}
