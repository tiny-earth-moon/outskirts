import Configuration
@testable import Frontend
import SystemPackage
import XCTest

final class IndexStoreWarningsTest: XCTestCase {
    private let derivedData = FilePath("/Users/dev/Library/Developer/Xcode/DerivedData")

    func testDefaultPrintsBothWarningsAsBefore() {
        let configuration = configuration(paths: ["/repo/.build/debug/index/store"])

        XCTAssertEqual(warnings(configuration), [
            "When using the '--index-store-path' option please ensure that Xcode is not running. False-positives can occur if Xcode writes to the index store while outskirts is running.",
            "The '--index-store-path' option implies '--skip-build', specify it to silence this warning.",
        ])
    }

    func testDefaultWithSkipBuildPrintsOnlyTheXcodeWarning() {
        let configuration = configuration(paths: ["/repo/.build/debug/index/store"])
        configuration.skipBuild = true

        XCTAssertEqual(warnings(configuration), [Scan.xcodeRunningWarning])
    }

    func testNoIndexStorePathPrintsNothing() {
        XCTAssertEqual(warnings(configuration(paths: [], quiet: true)), [])
        XCTAssertEqual(warnings(configuration(paths: [])), [])
    }

    func testQuietModeWithASwiftPMStorePrintsNothing() {
        XCTAssertEqual(warnings(configuration(paths: ["/repo/.build/debug/index/store"], quiet: true)), [])
        XCTAssertEqual(warnings(configuration(paths: [".build/debug/index/store"], quiet: true)), [])
    }

    func testQuietModeWithADerivedDataStoreKeepsTheXcodeWarning() {
        let store: FilePath = "/Users/dev/Library/Developer/Xcode/DerivedData/App-abc/Index.noindex/DataStore"

        XCTAssertEqual(warnings(configuration(paths: [store], quiet: true)), [Scan.xcodeRunningWarning])
        XCTAssertEqual(warnings(configuration(paths: ["/repo/.build/store", store], quiet: true)), [Scan.xcodeRunningWarning])
    }

    func testQuietModeResolvesRelativeStoresFromTheProjectRoot() {
        let configuration = configuration(paths: ["../Library/Developer/Xcode/DerivedData/App-abc/Index.noindex/DataStore"], quiet: true)
        configuration.projectRoot = "/Users/dev/repo"

        XCTAssertEqual(warnings(configuration), [Scan.xcodeRunningWarning])
    }

    func testQuietModeIgnoresASiblingOfDerivedData() {
        let store: FilePath = "/Users/dev/Library/Developer/Xcode/DerivedDataBackup/App/Index.noindex/DataStore"

        XCTAssertEqual(warnings(configuration(paths: [store], quiet: true)), [])
    }

    // MARK: - Private

    private func configuration(paths: [FilePath], quiet: Bool = false) -> Configuration {
        let configuration = Configuration()
        configuration.indexStorePath = paths
        configuration.quietIndexStore = quiet
        configuration.projectRoot = "/repo"
        return configuration
    }

    private func warnings(_ configuration: Configuration) -> [String] {
        Scan.indexStoreWarnings(for: configuration, xcodeDerivedDataRoot: derivedData)
    }
}
