import Configuration
import SourceGraph
import SystemPackage

struct XibIndexing: ResourceIndexingStrategy {
    static let loggerContext = "xib"

    let collectsNamedColors: Bool
    let collectsNamedImages: Bool

    init(configuration: Configuration) {
        collectsNamedColors = configuration.detectUnusedAssetCatalogColors
        collectsNamedImages = configuration.detectUnusedAssetCatalogImages
    }

    static func parseFailureDescription(path: FilePath, underlyingError: Error) -> String {
        "Failed to parse '\(path.string)': \(underlyingError.localizedDescription)"
    }

    func index(_ path: FilePath, into graph: SourceGraphMutex) throws {
        let parser = XibParser(path: path)
        let refs = try parser.parse()
        let assetNames = collectsNamedColors || collectsNamedImages
            ? try parser.namedAssets(colors: collectsNamedColors, images: collectsNamedImages)
            : []
        graph.withLock { graph in
            refs.forEach { graph.add($0) }
            graph.addAssetCatalogNameReferences(assetNames)
        }
    }
}

struct InfoPlistIndexing: ResourceIndexingStrategy {
    static let loggerContext = "infoplist"

    let collectsImageNames: Bool

    init(configuration: Configuration) {
        collectsImageNames = configuration.detectUnusedAssetCatalogImages
    }

    static func parseFailureDescription(path: FilePath, underlyingError: Error) -> String {
        "Failed to parse '\(path.string)': \(underlyingError.localizedDescription)"
    }

    func index(_ path: FilePath, into graph: SourceGraphMutex) throws {
        let parser = InfoPlistParser(path: path)
        let refs = try parser.parse()
        let imageNames = try collectsImageNames ? parser.imageNames() : []
        graph.withLock { graph in
            refs.forEach { graph.add($0) }
            graph.addAssetCatalogNameReferences(imageNames)
        }
    }
}

struct XCDataModelIndexing: ResourceIndexingStrategy {
    static let loggerContext = "xcdatamodel"

    static func parseFailureDescription(path: FilePath, underlyingError: Error) -> String {
        "Could not read or parse Core Data model at \(path.string): \(underlyingError.localizedDescription)"
    }

    func index(_ path: FilePath, into graph: SourceGraphMutex) throws {
        let input = try ModelInput(path: path, kind: .data)
        let refs = try XCDataModelParser(input: input).parse()
        graph.withLock { graph in
            refs.forEach { graph.add($0) }
        }
    }
}

struct XCMappingModelIndexing: ResourceIndexingStrategy {
    static let loggerContext = "xcmappingmodel"

    static func parseFailureDescription(path: FilePath, underlyingError: Error) -> String {
        "Could not read or parse Core Data mapping model at \(path.string): \(underlyingError.localizedDescription)"
    }

    func index(_ path: FilePath, into graph: SourceGraphMutex) throws {
        let input = try ModelInput(path: path, kind: .mapping)
        let refs = try XCMappingModelParser(input: input).parse()
        graph.withLock { graph in
            refs.forEach { graph.add($0) }
        }
    }
}
