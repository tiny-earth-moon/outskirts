import Foundation
@testable import Indexer
@testable import SourceGraph
import SystemPackage
@testable import TestShared
import XCTest

final class XibParserTest: XCTestCase {
    func testThrowsForMissingFile() {
        XCTAssertThrowsError(try XibParser(path: missingPath("xib")).parse())
    }

    func testThrowsForMissingFileWhenCollectingNamedColors() {
        XCTAssertThrowsError(try XibParser(path: missingPath("xib")).namedColors())
    }

    func testNamedAssets_collectsImageNames() throws {
        let parser = XibParser(path: FixturesProjectPath.appending("AssetCatalogs/FixtureImageView.xib"))

        XCTAssertEqual(try parser.namedAssets(colors: false, images: true), ["FixtureXibImage", "FixtureXibButtonImage"])
        XCTAssertEqual(try parser.namedAssets(colors: true, images: false), [])
    }

    func testParse_reportsActionsSentToTheFirstResponder() throws {
        let references = try XibParser(path: FixturesProjectPath.appending("AssetCatalogs/FixtureFirstResponder.xib")).parse()
        let actionsByName = Dictionary(uniqueKeysWithValues: references.map { ($0.name, Set($0.actions)) })

        XCTAssertEqual(actionsByName[AssetReference.firstResponderName], ["showPreferences:"])
        XCTAssertEqual(actionsByName["FixtureOwner"], ["ownerAction:"])
    }

    func testParse_reportsMenuActionsSentToTheMacOSFirstResponder() throws {
        let references = try XibParser(path: FixturesProjectPath.appending("AssetCatalogs/FixtureMainMenu.xib")).parse()

        XCTAssertEqual(references.first { $0.name == AssetReference.firstResponderName }?.actions, ["showPreferences:"])
        XCTAssertEqual(references.filter { $0.name != AssetReference.firstResponderName }.flatMap(\.actions), [])
    }

    func testNamedAssets_keepsColorsAndImagesApart() throws {
        let parser = XibParser(path: FixturesProjectPath.appending("AssetCatalogs/FixtureView.xib"))

        XCTAssertEqual(try parser.namedAssets(colors: false, images: true), [])
        XCTAssertEqual(try parser.namedColors(), ["FixtureXibColor"])
    }
}

private func missingPath(_ fileExtension: String) -> FilePath {
    FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("Missing-\(UUID().uuidString).\(fileExtension)").path)
}
