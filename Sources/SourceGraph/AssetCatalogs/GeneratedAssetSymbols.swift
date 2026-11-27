import Configuration
import Foundation
import SystemPackage

/// The asset catalog symbols Xcode generates in `GeneratedAssetSymbols.swift`, e.g.
/// `static let accent = ColorResource(name: "AccentColor", bundle: resourceBundle)` and the `Color.accent`,
/// `ShapeStyle.accent`, `UIColor.accent` and `NSColor.accent` accessors that wrap it, or
/// `static let logo = ImageResource(name: "Logo", bundle: resourceBundle)` and the `UIImage.logo` and `NSImage.logo`
/// accessors.
enum GeneratedAssetSymbols {
    /// An asset of a generated file, with its symbols and whether its name is referenced as a string.
    struct Asset {
        let kind: AssetCatalogSymbolKind
        let name: String?
        let declarations: [Declaration]
        let isReferencedByName: Bool
    }

    private struct AssetKey: Hashable, Comparable {
        let kind: AssetCatalogSymbolKind
        let symbolName: String

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.kind.rawValue, lhs.symbolName) < (rhs.kind.rawValue, rhs.symbolName)
        }
    }

    /// The assets of the generated files analyzed with the given configuration, by file, kind and symbol name.
    static func assets(in graph: SourceGraph, configuration: Configuration) throws -> [Asset] {
        let kinds = AssetCatalogSymbolKind.detected(by: configuration)
        guard !kinds.isEmpty else { return [] }

        let rootsByFile = Dictionary(grouping: rootDeclarations(in: graph, configuration: configuration)) { $0.location.file.path }
        var assets: [Asset] = []

        for (file, fileRoots) in rootsByFile.sorted(by: { $0.key.string < $1.key.string }) {
            let symbolsByKey = Dictionary(grouping: symbols(in: fileRoots, kinds: kinds)) { AssetKey(kind: $0.1, symbolName: $0.0.name) }
            var assetNamesByKind: [AssetCatalogSymbolKind: [String: String]] = [:]

            for (key, assetSymbols) in symbolsByKey.sorted(by: { $0.key < $1.key }) {
                if assetNamesByKind[key.kind] == nil {
                    assetNamesByKind[key.kind] = try assetNames(in: file, kind: key.kind)
                }

                let name = assetNamesByKind[key.kind]?[key.symbolName]
                assets.append(Asset(
                    kind: key.kind,
                    name: name,
                    declarations: assetSymbols.map(\.0).sorted(),
                    isReferencedByName: name.map { graph.assetCatalogNameReferences.contains($0) } ?? false
                ))
            }
        }

        return assets
    }

    /// The root declarations of the generated files analyzed with the given configuration.
    static func rootDeclarations(in graph: SourceGraph, configuration: Configuration) -> [Declaration] {
        graph.rootDeclarations
            .filter { configuration.isAnalyzedGeneratedAssetSymbolsFile($0.location.file.path) }
            .sorted()
    }

    /// The kind of asset whose symbol the declaration is, `nil` when it is not an asset symbol.
    static func symbolKind(of declaration: Declaration, in kinds: [AssetCatalogSymbolKind]) -> AssetCatalogSymbolKind? {
        guard [.varStatic, .varClass].contains(declaration.kind), let parentName = declaration.parent?.name else { return nil }

        return kinds.first { $0.symbolTypeNames.contains(parentName) }
    }

    /// The asset symbol declarations of the given roots, by kind.
    static func symbols(in roots: [Declaration], kinds: [AssetCatalogSymbolKind]) -> [(Declaration, AssetCatalogSymbolKind)] {
        roots.flatMap { root in
            ([root] + root.descendentDeclarations.sorted()).compactMap { declaration in
                symbolKind(of: declaration, in: kinds).map { (declaration, $0) }
            }
        }
    }

    /// The asset names of the resource symbols declared in the generated file, by symbol name.
    static func assetNames(in file: FilePath, kind: AssetCatalogSymbolKind) throws -> [String: String] {
        let contents = try String(contentsOfFile: file.string, encoding: .utf8)
        let type = NSRegularExpression.escapedPattern(for: kind.resourceTypeName)
        let pattern = #"static\s+let\s+`?(\w+)`?\s*=\s*(?:DeveloperToolsSupport\.)?"# + type + #"\(\s*name:\s*"((?:[^"\\]|\\.)*)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(contents.startIndex..., in: contents)

        return regex.matches(in: contents, range: range).reduce(into: [:]) { result, match in
            guard let symbol = Range(match.range(at: 1), in: contents),
                  let name = Range(match.range(at: 2), in: contents)
            else { return }

            result[String(contents[symbol])] = unescape(String(contents[name]))
        }
    }

    // MARK: - Private

    private static func unescape(_ literal: String) -> String {
        literal
            .replacingOccurrences(of: #"\""#, with: #"""#)
            .replacingOccurrences(of: #"\\"#, with: #"\"#)
    }
}
