import Configuration
import Foundation
import Logger
import Shared
@testable import SourceGraph
import SystemPackage
import XCTest

/// `report_test_only` with the generated symbols of an asset catalog, which `AssetCatalogSymbolMarker` groups by asset
/// after the walks.
final class TestOnlyAssetCatalogSymbolTest: XCTestCase {
    private var directory: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = NSTemporaryDirectory() + "outskirts-test-only-assets-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: directory)
        try super.tearDownWithError()
    }

    func testSymbolUsedOnlyByTests_isNotTestOnlyWhenTheAppUsesAnotherSymbolOfTheAsset() throws {
        let generatedPath = directory + "/" + Configuration.generatedAssetSymbolsFileName
        try """
        extension ColorResource {
            static let brand = ColorResource(name: "Brand", bundle: resourceBundle)
        }
        """.write(toFile: generatedPath, atomically: true, encoding: .utf8)

        let generated = SourceFile(path: FilePath(generatedPath), modules: ["App"])
        let app = SourceFile(path: FilePath(directory + "/App.swift"), modules: ["App"])
        let tests = SourceFile(path: FilePath(directory + "/AppTests.swift"), modules: ["AppTests"], isTestFile: true)

        let configuration = Configuration()
        configuration.apply(\.$reportTestOnly, true)
        configuration.apply(\.$detectUnusedAssetCatalogColors, true)
        let graph = SourceGraph(configuration: configuration, logger: Logger(quiet: true, verbose: false, colorMode: .never))

        let resource = addSymbol(to: graph, in: "ColorResource", usr: "resource", file: generated)
        let color = addSymbol(to: graph, in: "Color", usr: "color", file: generated)
        addRetainedFunction(to: graph, referencing: resource, file: app)
        addRetainedFunction(to: graph, referencing: color, file: tests)
        graph.indexingComplete()

        let swiftVersion = try SwiftVersion(shell: ShellImpl(logger: Logger(quiet: true, verbose: false, colorMode: .never)))
        try UsedDeclarationMarker(graph: graph, configuration: configuration, swiftVersion: swiftVersion).mutate()

        XCTAssertTrue(graph.isUsed(color))
        XCTAssertNil(graph.testOnlyEntries[color])
        XCTAssertTrue(graph.testOnlyDeclarations.isEmpty)
    }

    // MARK: - Private

    /// Adds `static var brand` in an extension of the named type, as Xcode generates it.
    private func addSymbol(to graph: SourceGraph, in typeName: String, usr: String, file: SourceFile) -> Declaration {
        let location = Location(file: file, line: 1, column: 1)
        let extensionDeclaration = Declaration(name: typeName, kind: .extensionStruct, usrs: ["extension-\(usr)"], location: location)
        let symbol = Declaration(name: "brand", kind: .varStatic, usrs: [usr], location: location)
        symbol.parent = extensionDeclaration
        extensionDeclaration.declarations.insert(symbol)
        graph.add(extensionDeclaration)
        graph.add(symbol)
        return symbol
    }

    private func addRetainedFunction(to graph: SourceGraph, referencing declaration: Declaration, file: SourceFile) {
        let location = Location(file: file, line: 1, column: 1)
        let function = Declaration(name: "use\(declaration.usrs.sorted()[0])()", kind: .functionFree, usrs: ["use-\(file.path)"], location: location)
        let reference = Reference(name: "brand", kind: .normal, declarationKind: .varStatic, usr: declaration.usrs.sorted()[0], location: location)
        reference.parent = function
        graph.add(function)
        graph.add(reference, from: function)
        graph.markRetained(function)
    }
}
