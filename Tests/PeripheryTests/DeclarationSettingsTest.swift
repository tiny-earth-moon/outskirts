import Configuration
import Foundation
import SystemPackage
import XCTest

/// The settings of one declaration: the top-level ones, changed by the overrides of a configuration v2 file that match
/// its modules and its file.
final class DeclarationSettingsTest: XCTestCase {
    private var directory: FilePath!

    private func configuration(_ yaml: String) throws -> Configuration {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("outskirts-overrides-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        self.directory = FilePath(directory.path)
        let file = FilePath(directory.appendingPathComponent(".outskirts.yml").path)
        try ("version: 2\n" + yaml).write(to: file.url, atomically: true, encoding: .utf8)

        let configuration = Configuration()
        try configuration.load(from: file) { XCTFail("unexpected warning: \($0)") }
        return configuration
    }

    func testWithoutOverridesTheTopLevelSettingsApply() throws {
        let settings = try configuration("retain: {public_modules: [Kit]}\n").settings(forModules: ["Kit"], path: "/p/Kit/A.swift")

        XCTAssertEqual(settings.publicRetentionKey, "retain_public_modules")
        XCTAssertFalse(settings.retainsAll)
        XCTAssertTrue(settings.isEnabled(.redundantPublic))
    }

    func testLastMatchingOverrideWinsPerSetting() throws {
        let configuration = try configuration("""
        overrides:
          - modules: [Kit]
            rules: {redundant-public: off, unused-parameter: off}
            retain: {public: true}
          - paths: ["/p/Kit/Generated/**"]
            rules: {redundant-public: on}
            retain: {all: true}
        """)

        let generated = configuration.settings(forModules: ["Kit"], path: "/p/Kit/Generated/A.swift")
        XCTAssertTrue(generated.isEnabled(.redundantPublic))
        XCTAssertFalse(generated.isEnabled(.unusedParameter))
        XCTAssertTrue(generated.retainsAll)
        XCTAssertEqual(generated.publicRetentionKey, "overrides")

        let handWritten = configuration.settings(forModules: ["Kit"], path: "/p/Kit/A.swift")
        XCTAssertFalse(handWritten.isEnabled(.redundantPublic))
        XCTAssertFalse(handWritten.retainsAll)

        let other = configuration.settings(forModules: ["App"], path: "/p/App/Generated/A.swift")
        XCTAssertTrue(other.isEnabled(.redundantPublic))
        XCTAssertNil(other.publicRetentionKey)
    }

    func testLaterOverrideTurningARuleOffWinsOverAnEarlierOne() throws {
        let configuration = try configuration("""
        overrides:
          - paths: ["/p/**"]
            rules: {unused-parameter: on}
          - modules: ["K*"]
            rules: {unused-parameter: off}
        """)

        XCTAssertFalse(configuration.settings(forModules: ["Kit"], path: "/p/Kit/A.swift").isEnabled(.unusedParameter))
        XCTAssertTrue(configuration.settings(forModules: ["App"], path: "/p/App/A.swift").isEnabled(.unusedParameter))
    }

    func testOverrideCancelsTheRetainedPublicModules() throws {
        let configuration = try configuration("""
        retain: {public_modules: [Kit]}
        overrides:
          - paths: ["/p/Kit/Internal/**"]
            retain: {public: false}
        """)

        XCTAssertNil(configuration.settings(forModules: ["Kit"], path: "/p/Kit/Internal/A.swift").publicRetentionKey)
        XCTAssertEqual(configuration.settings(forModules: ["Kit"], path: "/p/Kit/A.swift").publicRetentionKey, "retain_public_modules")
    }

    /// Relative path globs are anchored to the directory of the file, and compared with the absolute file.
    func testRelativePathGlobMatchesTheAbsoluteFileOnly() throws {
        let configuration = try configuration("overrides:\n  - paths: [\"Sources/**\"]\n    retain: {all: true}\n")

        XCTAssertTrue(configuration.settings(forModules: ["Kit"], path: directory.appending("Sources/Kit/A.swift")).retainsAll)
        XCTAssertFalse(configuration.settings(forModules: ["Kit"], path: "Sources/Kit/A.swift").retainsAll)
    }

    func testOverrideWithModulesAndPathsNeedsBoth() throws {
        let configuration = try configuration("""
        overrides:
          - modules: [Kit]
            paths: ["/p/Kit/**"]
            retain: {all: true}
        """)

        XCTAssertTrue(configuration.settings(forModules: ["Kit", "KitTests"], path: "/p/Kit/A.swift").retainsAll)
        XCTAssertFalse(configuration.settings(forModules: ["App"], path: "/p/Kit/A.swift").retainsAll)
        XCTAssertFalse(configuration.settings(forModules: ["Kit"], path: "/p/App/A.swift").retainsAll)
    }
}
