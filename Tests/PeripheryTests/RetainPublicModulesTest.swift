import Configuration
import Foundation
import Logger
@testable import PeripheryKit
import SourceGraph
import SystemPackage
@testable import TestShared
import XCTest

/// `retain_public_modules` retains the public declarations of a library whose interface is consumed elsewhere, and
/// keeps reporting the unused public declarations of an executable of the same package.
final class RetainPublicModulesTest: SPMSourceGraphTestCase {
    private static let libraryModule = "RetainPublicLib"
    private static let executableModule = "RetainPublicApp"

    override static func setUp() {
        super.setUp()

        build(projectPath: ExecutableFixturesProjectPath)
    }

    func testListedModulesRetainTheirPublicDeclarationsOnly() {
        analyze(retainPublicModules: [Self.libraryModule])

        module(Self.libraryModule) {
            self.assertReferenced(.class("PublicLibClass"))
            self.assertReferenced(.functionFree("publicLibFunction()"))
            self.assertReferenced(.enum("PublicLibEnum")) {
                self.assertReferenced(.enumelement("first"))
            }
            self.assertReferenced(.class("OpenLibClass")) {
                self.assertReferenced(.functionMethodInstance("overridable(_:)"))
            }
            self.assertNotRedundantPublicAccessibility(.functionFree("publicLibHelper()"))
            self.assertNotRedundantOpenAccessibility(.class("OpenLibClass"))
            self.assertNotReferenced(.functionFree("internalLibFunction()"))
        }

        module(Self.executableModule) {
            self.assertNotReferenced(.functionFree("unusedPublicAppFunction()"))
            self.assertRedundantPublicAccessibility(.functionFree("usedPublicAppFunction()"))
        }
    }

    /// A listed module has the results of `retain_public: true`, any other module those of `retain_public: false`.
    func testListedModulesReportAsWithRetainPublicAndOtherModulesAsWithout() {
        analyze(retainPublic: true)
        let retainingAll = describedResults()
        analyze(retainPublic: false)
        let retainingNone = describedResults()
        analyze(retainPublicModules: [Self.libraryModule])
        let retainingLibrary = describedResults()

        XCTAssertEqual(retainingLibrary[Self.libraryModule], retainingAll[Self.libraryModule])
        XCTAssertEqual(retainingLibrary[Self.executableModule], retainingNone[Self.executableModule])
        XCTAssertNotEqual(retainingAll[Self.libraryModule], retainingNone[Self.libraryModule])
    }

    func testRetainPublicStillRetainsEveryModule() {
        analyze(retainPublic: true, retainPublicModules: [Self.executableModule])

        module(Self.libraryModule) {
            self.assertReferenced(.class("PublicLibClass"))
            self.assertNotReferenced(.functionFree("internalLibFunction()"))
        }

        module(Self.executableModule) {
            self.assertReferenced(.functionFree("unusedPublicAppFunction()"))
        }
    }

    func testWithoutRetentionEveryUnusedPublicDeclarationIsReported() {
        analyze(retainPublic: false)

        module(Self.libraryModule) {
            self.assertNotReferenced(.class("PublicLibClass"))
            self.assertNotReferenced(.functionFree("publicLibFunction()"))
        }

        module(Self.executableModule) {
            self.assertNotReferenced(.functionFree("unusedPublicAppFunction()"))
        }
    }

    func testUnknownModuleRetainsNothing() {
        analyze(retainPublicModules: ["NotAModule"])

        module(Self.libraryModule) {
            self.assertNotReferenced(.class("PublicLibClass"))
        }
    }

    func testWarnsAboutListedModulesThatAreNotScanned() throws {
        let warnings = try mutatorWarnings(retainPublicModules: [Self.libraryModule, "NotAModule"], scannedModules: [Self.libraryModule])

        XCTAssertEqual(warnings, "warning: retain_public_modules lists modules that are not scanned, whose public declarations are therefore not retained: NotAModule\n")
    }

    func testDoesNotWarnWhenEveryListedModuleIsScanned() throws {
        let warnings = try mutatorWarnings(retainPublicModules: [Self.libraryModule], scannedModules: [Self.libraryModule, Self.executableModule])

        XCTAssertEqual(warnings, "")
    }

    // MARK: - Overrides (configuration v2)

    /// An override retains the public declarations of one module only, the redundant public analysis still reports the
    /// other one, with the results of `retain_public_modules` for the same module.
    func testOverrideRetainsThePublicDeclarationsOfOneModuleOnly() throws {
        try analyze(v2: """
        overrides:
          - modules: ["RetainPublicL*"]
            retain: {public: true}
        """)
        let retainingByOverride = describedResults()

        module(Self.libraryModule) {
            self.assertReferenced(.class("PublicLibClass"))
            self.assertNotRedundantPublicAccessibility(.functionFree("publicLibHelper()"))
            self.assertNotReferenced(.functionFree("internalLibFunction()"))
        }

        module(Self.executableModule) {
            self.assertNotReferenced(.functionFree("unusedPublicAppFunction()"))
            self.assertRedundantPublicAccessibility(.functionFree("usedPublicAppFunction()"))
        }

        analyze(retainPublicModules: [Self.libraryModule])
        XCTAssertEqual(retainingByOverride, describedResults())
    }

    /// An override matching the files of a module retains all their declarations.
    func testOverrideRetainsEveryDeclarationOfTheMatchedFiles() throws {
        try analyze(v2: """
        overrides:
          - paths: ["\(Self.executableModule)/**"]
            retain: {all: true}
        """)

        module(Self.executableModule) {
            self.assertReferenced(.functionFree("unusedPublicAppFunction()"))
        }

        module(Self.libraryModule) {
            self.assertNotReferenced(.functionFree("internalLibFunction()"))
        }
    }

    /// An override turning a rule off drops its results for the declarations it matches only.
    func testOverrideTurnsARuleOffForTheMatchedModules() throws {
        let configuration = try analyze(v2: """
        overrides:
          - modules: [\(Self.executableModule)]
            rules: {redundant-public: off}
        """)
        let results = try OutputDeclarationFilter(configuration: configuration, logger: Self.logger).filter(Self.results, with: nil)

        func redundantPublicModules(_ results: [ScanResult]) -> Set<String> {
            Set(results.filter { $0.overridableRule == .redundantPublic }.flatMap(\.declaration.location.file.modules))
        }

        XCTAssertEqual(redundantPublicModules(Self.results), [Self.libraryModule, Self.executableModule])
        XCTAssertEqual(redundantPublicModules(results), [Self.libraryModule])
        XCTAssertTrue(results.contains { $0.declaration.name == "unusedPublicAppFunction()" })
    }

    // MARK: - Private

    /// Analyzes the fixture with a configuration v2 file written next to its sources, which the paths of the file
    /// start from.
    @discardableResult
    private func analyze(v2 yaml: String) throws -> Configuration {
        let file = ExecutableFixturesProjectPath.appending("Sources/.outskirts-test-\(UUID().uuidString).yml")
        try ("version: 2\nrules: {redundant-open: on, missing-final: on}\n" + yaml).write(to: file.url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file.url) }

        let configuration = Configuration()
        try configuration.load(from: file) { XCTFail("unexpected warning: \($0)") }

        let sources = ["\(Self.libraryModule)/RetainPublicLib.swift", "\(Self.executableModule)/main.swift"]
        index(sourceFiles: sources.map { ExecutableFixturesProjectPath.appending("Sources/\($0)") }, configuration: configuration)
        return configuration
    }

    /// What running the mutators writes to stderr, with a logger that is not quiet.
    private func mutatorWarnings(retainPublicModules: [String], scannedModules: Set<String>) throws -> String {
        let configuration = Configuration()
        configuration.retainPublicModules = retainPublicModules
        let logger = Logger(quiet: false, verbose: false, colorMode: .never)
        let graph = SourceGraph(configuration: configuration, logger: logger)
        graph.addIndexedModules(scannedModules)
        let runner = SourceGraphMutatorRunner(graph: graph, logger: logger, configuration: configuration, swiftVersion: Self.swiftVersion)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("outskirts-retain-public-modules-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }

        fflush(nil)
        let saved = dup(STDERR_FILENO)
        let target = open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        dup2(target, STDERR_FILENO)
        close(target)
        defer {
            fflush(nil)
            dup2(saved, STDERR_FILENO)
            close(saved)
        }

        try runner.perform()
        fflush(nil)

        return try String(contentsOf: file, encoding: .utf8)
    }

    private func analyze(retainPublic: Bool = false, retainPublicModules: [String] = []) {
        let configuration = Configuration()
        configuration.retainPublic = retainPublic
        configuration.retainPublicModules = retainPublicModules
        configuration.enableOpenFinalAnalysis = true

        let sources = ["\(Self.libraryModule)/RetainPublicLib.swift", "\(Self.executableModule)/main.swift"]
        index(sourceFiles: sources.map { ExecutableFixturesProjectPath.appending("Sources/\($0)") }, configuration: configuration)
    }

    /// The results of the last analysis by module, each described by its annotation, kind, name and line.
    private func describedResults() -> [String: [String]] {
        var results: [String: [String]] = [:]

        for result in Self.results {
            let declaration = result.declaration
            let description = "\(result.annotation) \(declaration.kind) \(declaration.name) \(declaration.location.line)"

            for module in declaration.location.file.modules {
                results[module, default: []].append(description)
            }
        }

        return results.mapValues { $0.sorted() }
    }
}
