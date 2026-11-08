@testable import Configuration
import SystemPackage
import XCTest

final class BuildPluginOutputsExcludeTest: XCTestCase {
    private let pluginOutput = FilePath.current.appending(".build/plugins/outputs/app/App/destination/Gen/Generated.swift")
    private let derivedSource = FilePath.current.appending(".build/arm64-apple-macosx/debug/App.build/DerivedSources/resource_bundle_accessor.swift")
    private let checkout = FilePath.current.appending(".build/checkouts/Dependency/Sources/Dependency/File.swift")

    private func configuration(_ configure: (Configuration) -> Void = { _ in }) -> Configuration {
        let configuration = Configuration()
        configure(configuration)
        configuration.buildFilenameMatchers()
        return configuration
    }

    func testPluginOutputs_areIndexedUnlessAGivenGlobExcludesThem() {
        let defaults = configuration()
        XCTAssertFalse(defaults.isIndexExcluded(pluginOutput))
        XCTAssertTrue(defaults.isIndexExcluded(derivedSource))
        XCTAssertTrue(defaults.isIndexExcluded(checkout))

        let given = configuration { $0.indexExclude = ["**/plugins/outputs/app/**"] }
        XCTAssertTrue(given.isIndexExcluded(pluginOutput))

        let givenWithoutDefaults = configuration {
            $0.$indexExclude.isNormalizing = false
            $0.indexExclude = ["**/*?.build/**/*"]
        }
        XCTAssertTrue(givenWithoutDefaults.isIndexExcluded(pluginOutput))
    }

    func testReportExclude_defaultsToThePluginOutputs() {
        XCTAssertEqual(Configuration().reportExclude, [.pattern("**/plugins/outputs/**")])
        XCTAssertTrue(Configuration().isBuildPluginOutput(pluginOutput))
        XCTAssertFalse(Configuration().isBuildPluginOutput(derivedSource))
    }

    func testReportExclude_keepsTheDefaultAfterTheGivenEntries() {
        let configuration = Configuration()
        configuration.reportExclude = [.pattern("**/Generated/**"), .pattern(Configuration.buildPluginOutputsGlob)]
        XCTAssertEqual(configuration.reportExclude, [.pattern("**/Generated/**"), .pattern(Configuration.buildPluginOutputsGlob)])

        configuration.reportExclude = [.scoped(path: "**/Kit/**", kinds: ["unused"])]
        XCTAssertEqual(configuration.reportExclude, [.scoped(path: "**/Kit/**", kinds: ["unused"]), .pattern(Configuration.buildPluginOutputsGlob)])
    }
}
