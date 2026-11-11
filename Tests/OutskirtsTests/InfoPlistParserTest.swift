import Foundation
@testable import Indexer
import SystemPackage
@testable import TestShared
import XCTest

final class InfoPlistParserTest: XCTestCase {
    func testThrowsForMissingFile() {
        XCTAssertThrowsError(try InfoPlistParser(path: missingPath("plist")).parse())
    }

    func testImageNames_collectsLaunchScreenShortcutAndAppIconNames() throws {
        let parser = InfoPlistParser(path: FixturesProjectPath.appending("AssetCatalogs/FixtureInfo.plist"))

        XCTAssertEqual(try parser.imageNames(), ["AppIcon", "FixtureLaunchImage", "FixtureShortcutImage"])
        XCTAssertEqual(try parser.parse().map(\.name), [])
    }
}
