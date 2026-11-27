import Configuration
import Foundation
import Shared
import SystemPackage

/// Reports each asset whose generated symbols are all unused once, on its resource symbol
/// (e.g. `ColorResource.accent`), and keeps the other symbols of the asset (e.g. `Color.accent`) out of the
/// results. An asset with any used symbol, or whose name is referenced as a string (e.g. `Color("AccentColor")`,
/// `UIImage(named: "Logo")`, an Interface Builder named color or image, an Info.plist launch image or the global
/// accent color build setting), is used.
final class AssetCatalogSymbolMarker: SourceGraphMutator {
    private let graph: SourceGraph
    private let configuration: Configuration

    required init(graph: SourceGraph, configuration: Configuration, swiftVersion _: SwiftVersion) {
        self.graph = graph
        self.configuration = configuration
    }

    func mutate() throws {
        let assets = try GeneratedAssetSymbols.assets(in: graph, configuration: configuration)
        guard !assets.isEmpty else { return }

        let locator = AssetCatalogLocator(root: FilePath.current)

        for asset in assets {
            let declarations = asset.declarations

            if asset.isReferencedByName || declarations.contains(where: graph.isUsed) {
                declarations.forEach(graph.markUsed)
                continue
            }

            let resource = declarations.first { $0.parent?.name == asset.kind.resourceTypeName } ?? declarations[0]

            for declaration in declarations where declaration != resource {
                graph.markIgnored(declaration)
            }

            let assetPaths = asset.name.map { locator.assetPaths(named: $0, kind: asset.kind) } ?? []
            graph.markUnusedAssetCatalogSymbol(
                resource,
                symbol: AssetCatalogSymbol(kind: asset.kind, assetName: asset.name, assetPaths: assetPaths)
            )
        }
    }
}
