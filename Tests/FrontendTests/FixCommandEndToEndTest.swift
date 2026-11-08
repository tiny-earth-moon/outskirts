import Foundation
@testable import TestShared
import XCTest

/// Runs `outskirts fix` on a small package in a git repository: the dry run, the dirty-file refusal, `--apply`,
/// the rescan of the fixed package, which must build and report nothing more to fix, `--verify` and `--aggressive`.
final class FixCommandEndToEndTest: XCTestCase {
    private static let options = [
        "--disable-update-check", "--enable-empty-extension-analysis", "--superfluous-ignore-comments",
        "--enable-redundant-access-level-analysis",
    ]

    private static let library = """
    // Fixture header.

    import Helpers

    public struct Widget {
        public init() {}

        public func render(width: Int, _ height: Int) -> Int {
            helper() + internalValue() + libraryOnly()
        }

        // periphery:ignore
        func helper() -> Int { 1 }

        internal func internalValue() -> Int { 2 }
    }

    public func libraryOnly() -> Int { 3 }

    /// Doc of the empty extension.
    extension Widget {}

    """

    private static let fixedLibrary = """
    // Fixture header.

    public struct Widget {
        public init() {}

        public func render(width _: Int, _: Int) -> Int {
            helper() + internalValue() + libraryOnly()
        }

        func helper() -> Int { 1 }

        func internalValue() -> Int { 2 }
    }

    public func libraryOnly() -> Int { 3 }

    """

    private var package: URL!

    override func setUpWithError() throws {
        package = FileManager.default.temporaryDirectory.appendingPathComponent("outskirts-fix-e2e-\(UUID().uuidString)")
        addTeardownBlock { [package] in
            if let package {
                try? FileManager.default.removeItem(at: package)
            }
        }

        try write("""
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Fixture", targets: [
            .target(name: "Helpers"),
            .target(name: "Lib", dependencies: ["Helpers"]),
            .executableTarget(name: "App", dependencies: ["Lib"]),
        ])
        """, to: "Package.swift")
        try write("public func helperValue() -> Int { 1 }\n", to: "Sources/Helpers/Helpers.swift")
        try write(Self.library, to: "Sources/Lib/Lib.swift")
        try write("import Lib\n\nprint(Widget().render(width: 1, 2))\n", to: "Sources/App/main.swift")
        try write(".build/\n", to: ".gitignore")
        try git("init", "-q")
        try commitAll()
    }

    func testFixesThePackageAndTheRescanIsClean() throws {
        try write(Self.library + "// uncommitted\n", to: "Sources/Lib/Lib.swift")
        let dirty = try run(["fix"])
        XCTAssertEqual(dirty.status, 0, dirty.stderr)
        XCTAssertEqual(dirty.stdout, "")
        XCTAssertTrue(dirty.stderr.contains("uncommitted changes, use --allow-dirty"), dirty.stderr)
        try write(Self.library, to: "Sources/Lib/Lib.swift")

        let dryRun = try run(["fix"])
        XCTAssertEqual(dryRun.status, 0, dryRun.stderr)
        XCTAssertTrue(dryRun.stdout.hasPrefix("--- a/Sources/Lib/Lib.swift\n+++ b/Sources/Lib/Lib.swift\n"), dryRun.stdout)
        XCTAssertTrue(dryRun.stderr.contains("Would apply 6 fixes in 1 file, skipped 0."), dryRun.stderr)
        XCTAssertEqual(try read("Sources/Lib/Lib.swift"), Self.library)

        let applied = try run(["fix", "--apply"])
        XCTAssertEqual(applied.status, 0, applied.stderr)
        XCTAssertEqual(applied.stdout, "")
        XCTAssertEqual(try read("Sources/Lib/Lib.swift"), Self.fixedLibrary)

        try commitAll()
        let rescan = try run(["fix"])
        XCTAssertEqual(rescan.status, 0, "the fixed package builds:\n\(rescan.stderr)")
        XCTAssertEqual(rescan.stdout, "")
        XCTAssertTrue(rescan.stderr.contains("Would apply 0 fixes in 0 files, skipped 0."), rescan.stderr)
    }

    func testFileEditedAfterItsIndexWasWrittenIsRefused() throws {
        let built = try run(["fix"])
        XCTAssertEqual(built.status, 0, built.stderr)

        try write(Self.library + "// edited after the build\n", to: "Sources/Lib/Lib.swift")
        try commitAll()
        let stale = try run(["fix", "--skip-build"])

        XCTAssertEqual(stale.status, 0, stale.stderr)
        XCTAssertEqual(stale.stdout, "")
        XCTAssertTrue(stale.stderr.contains("file changed since indexing"), stale.stderr)
    }

    func testRuleFilterOnlyAppliesTheGivenRule() throws {
        let output = try run(["fix", "--rule", "unused-parameter"])

        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertTrue(output.stdout.contains("+    public func render(width _: Int, _: Int) -> Int {"), output.stdout)
        XCTAssertFalse(output.stdout.contains("-import Helpers"), output.stdout)
        XCTAssertTrue(output.stderr.contains("Would apply 2 fixes in 1 file, skipped 0.\n  unused-parameter: 2"), output.stderr)
    }

    func testUnusedIsAnUnknownRule() throws {
        let output = try run(["fix", "--rule", "unused"])

        XCTAssertNotEqual(output.status, 0)
        XCTAssertTrue(output.stderr.contains("The value 'unused' is invalid for '--rule <rule>'"), output.stderr)
        XCTAssertEqual(try read("Sources/Lib/Lib.swift"), Self.library)
    }

    // MARK: - Uncovered conditional clauses

    func testUnusedImportUsedOnlyUnderNotDebugIsKept() throws {
        let release = "import Helpers\n\npublic func releaseValue() -> Int {\n    #if !DEBUG\n        return helperValue()\n    #else\n        return 0\n    #endif\n}\n"
        try write(release, to: "Sources/Lib/Release.swift")
        try commitAll()

        let output = try run(["fix", "--rule", "unused-import", "--apply"])

        XCTAssertEqual(output.status, 0, output.stderr)
        // A debug scan does not see the call, so the import looks unused, but the release build needs it.
        XCTAssertTrue(output.stderr.contains("  skipped unused-import 'Helpers' at Sources/Lib/Release.swift:1:8: file with code in an #if clause that no scanned build compiled"), output.stderr)
        XCTAssertEqual(try read("Sources/Lib/Release.swift"), release)
        XCTAssertFalse(try read("Sources/Lib/Lib.swift").contains("import Helpers"))
    }

    func testRedundantPublicUsedCrossModuleUnderNotDebugIsKept() throws {
        try write("import Lib\n\nprint(Widget().render(width: 1, 2))\n#if !DEBUG\n    print(libraryOnly())\n#endif\n", to: "Sources/App/main.swift")
        try commitAll()

        let output = try run(["fix", "--rule", "redundant-public", "--variants", "auto", "--apply"])

        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertTrue(output.stderr.contains("  skipped redundant-public 'libraryOnly()' at Sources/Lib/Lib.swift:18:13: name written in an #if clause that no scanned build compiled"), output.stderr)
        XCTAssertEqual(try read("Sources/Lib/Lib.swift"), Self.library)
    }

    func testOverridesInUncompiledClausesKeepOpen() throws {
        try write("open class PlatformBase {\n    public init() {}\n    open func hook() {}\n}\n\nopen class FlagBase {\n    public init() {}\n}\n", to: "Sources/Lib/Bases.swift")
        try write("import Lib\n\nprint(Widget().render(width: 1, 2), PlatformBase(), FlagBase())\n#if os(iOS)\n    final class PhoneSub: PlatformBase {\n        override func hook() {}\n    }\n#endif\n#if FEATURE\n    final class FlagSub: FlagBase {}\n#endif\n", to: "Sources/App/main.swift")
        try commitAll()

        let output = try run(["fix", "--rule", "redundant-open", "--enable-open-final-analysis", "--variants", "auto"])

        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertFalse(output.stdout.contains("Bases.swift"), output.stdout)
        XCTAssertTrue(output.stderr.contains("  skipped redundant-open 'FlagBase' at Sources/Lib/Bases.swift:6:12: name written in an #if clause that no scanned build compiled"), output.stderr)
    }

    func testRedundantPublicIsRefusedWhenExcludeTargetsLeavesItsClientOut() throws {
        try write("import Lib\n\nprint(Widget().render(width: 1, 2), libraryOnly())\n", to: "Sources/App/main.swift")
        try commitAll()

        let named = try run(["fix", "--rule", "redundant-public", "--variants", "auto", "--exclude-targets", "App"])
        XCTAssertNotEqual(named.status, 0)
        XCTAssertTrue(named.stderr.contains("'--rule redundant-public' is only safe when every file that may use the code it changes is scanned, but 'exclude_targets' leaves code out of the scan"), named.stderr)
        XCTAssertTrue(named.stderr.contains("Pass '--allow-partial-scan' to accept this."), named.stderr)
    }

    // MARK: - Opt-in redundant-public

    func testRedundantPublicIsNotAppliedByDefault() throws {
        let byDefault = try run(["fix", "--variants", "auto"])
        XCTAssertEqual(byDefault.status, 0, byDefault.stderr)
        XCTAssertFalse(byDefault.stdout.contains("-public func libraryOnly()"), byDefault.stdout)
        XCTAssertFalse(byDefault.stderr.contains("redundant-public"), byDefault.stderr)

        let aggressive = try run(["fix", "--aggressive", "--variants", "auto"])
        XCTAssertEqual(aggressive.status, 0, aggressive.stderr)
        XCTAssertFalse(aggressive.stdout.contains("-public func libraryOnly()"), aggressive.stdout)

        let named = try run(["fix", "--rule", "redundant-public", "--variants", "auto"])
        XCTAssertEqual(named.status, 0, named.stderr)
        XCTAssertTrue(named.stdout.contains("-public func libraryOnly() -> Int { 3 }\n+func libraryOnly() -> Int { 3 }"), named.stdout)
    }

    func testRedundantPublicIsRefusedOnALibraryProductWithoutRetainPublic() throws {
        try write("""
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Fixture", products: [.library(name: "Lib", targets: ["Lib"])], targets: [
            .target(name: "Helpers"),
            .target(name: "Lib", dependencies: ["Helpers"]),
            .executableTarget(name: "App", dependencies: ["Lib"]),
        ])
        """, to: "Package.swift")
        try commitAll()

        let output = try run(["fix", "--rule", "redundant-public", "--variants", "auto"])

        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertEqual(output.stdout, "")
        XCTAssertTrue(output.stderr.contains("  skipped redundant-public 'libraryOnly()' at Sources/Lib/Lib.swift:18:13: public API of a library product, clients outside the scan may use it"), output.stderr)
    }

    // MARK: - Partial scans

    func testMissingFinalIsRefusedWithExcludeTests() throws {
        try writeMockedBox()

        let named = try run(["fix", "--aggressive", "--rule", "missing-final", "--enable-open-final-analysis", "--variants", "auto", "--exclude-tests", "--apply"])
        XCTAssertNotEqual(named.status, 0)
        XCTAssertTrue(named.stderr.contains("but 'exclude_tests' leaves code out of the scan"), named.stderr)

        let byDefault = try run(["fix", "--aggressive", "--enable-open-final-analysis", "--variants", "auto", "--exclude-tests", "--apply"])
        XCTAssertEqual(byDefault.status, 0, byDefault.stderr)
        // The mock of the tests subclasses it, but the tests are not scanned.
        XCTAssertTrue(byDefault.stderr.contains("  skipped missing-final 'Box' at Sources/Lib/Box.swift:1:7: partial scan ('exclude_tests' leaves code out of the scan), use --allow-partial-scan"), byDefault.stderr)
        XCTAssertEqual(try read("Sources/Lib/Box.swift"), Self.box)

        let flagWithoutRule = try run(["fix", "--rule", "unused-import", "--allow-partial-scan"])
        XCTAssertNotEqual(flagWithoutRule.status, 0)
        XCTAssertTrue(flagWithoutRule.stderr.contains("'--allow-partial-scan' only applies to 'redundant-public', 'redundant-open', 'missing-final'"), flagWithoutRule.stderr)
    }

    func testMissingFinalIsRefusedWithIndexExclude() throws {
        try writeMockedBox()

        let named = try run(["fix", "--aggressive", "--rule", "missing-final", "--enable-open-final-analysis", "--variants", "auto", "--index-exclude", "Tests/**"])
        XCTAssertNotEqual(named.status, 0)
        XCTAssertTrue(named.stderr.contains("but 'index_exclude' leaves code out of the scan"), named.stderr)

        let scanned = try run(["fix", "--aggressive", "--rule", "missing-final", "--enable-open-final-analysis", "--variants", "auto"])
        XCTAssertEqual(scanned.status, 0, scanned.stderr)
        XCTAssertFalse(scanned.stdout.contains("final class Box"), scanned.stdout)
    }

    // MARK: - Dependency packages

    func testTierOneRulesKeepTheFilesOfALocalDependencyPackage() throws {
        try write("""
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Core", products: [.library(name: "Core", targets: ["Core"])], targets: [
            .target(name: "Core"),
        ])
        """, to: "Modules/Core/Package.swift")
        let core = "public func coreValue(_ unused: Int) -> Int { 1 }\n"
        try write(core, to: "Modules/Core/Sources/Core/Core.swift")
        try write("""
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Fixture", dependencies: [.package(path: "Modules/Core")], targets: [
            .target(name: "Helpers"),
            .target(name: "Lib", dependencies: ["Helpers"]),
            .executableTarget(name: "App", dependencies: ["Lib", .product(name: "Core", package: "Core")]),
        ])
        """, to: "Package.swift")
        try write("import Core\nimport Lib\n\nprint(Widget().render(width: 1, 2), coreValue(0))\n", to: "Sources/App/main.swift")
        try commitAll()

        let output = try run(["fix", "--apply"])

        XCTAssertEqual(output.status, 0, output.stderr)
        // Another client of the package, or its own tests, may need what this scan reports.
        XCTAssertTrue(output.stderr.contains("skipped unused-parameter 'unused' at Modules/Core/Sources/Core/Core.swift:1:25: dependency package"), output.stderr)
        XCTAssertEqual(try read("Modules/Core/Sources/Core/Core.swift"), core)
        XCTAssertEqual(try read("Sources/Lib/Lib.swift"), Self.fixedLibrary)
    }

    // MARK: - Verify

    func testVerifyKeepsTheFixesWhenTheProjectBuilds() throws {
        let output = try run(["fix", "--apply", "--verify"])

        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertTrue(output.stderr.contains("The project builds with the fixes."), output.stderr)
        XCTAssertEqual(try read("Sources/Lib/Lib.swift"), Self.fixedLibrary)
    }

    func testVerifyRestoresEveryFileWhenTheFixesBreakTheBuild() throws {
        // The client of `libraryOnly()` is excluded from the index, so its `public` is reported as redundant.
        try write("import Lib\n\nfunc excludedClient() -> Int { libraryOnly() }\n", to: "Sources/App/Excluded.swift")
        try commitAll()
        let originalBytes = try Data(contentsOf: package.appendingPathComponent("Sources/Lib/Lib.swift"))

        let output = try run(["fix", "--rule", "redundant-public", "--allow-partial-scan", "--apply", "--verify", "--index-exclude", "Sources/App/Excluded.swift"])

        XCTAssertNotEqual(output.status, 0, output.stderr)
        XCTAssertTrue(output.stderr.contains("The build failed after the fixes were applied"), output.stderr)
        XCTAssertTrue(output.stderr.contains("The fixes break the build, restored 1 of 1 file:\n  restored Sources/Lib/Lib.swift"), output.stderr)
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("Sources/Lib/Lib.swift")), originalBytes)
    }

    func testVerifyRefusesASkippedBuild() throws {
        let built = try run(["fix"])
        XCTAssertEqual(built.status, 0, built.stderr)

        for arguments in [["--skip-build"], ["--index-store-path", ".build/debug/index/store"]] {
            let output = try run(["fix", "--apply", "--verify"] + arguments)

            XCTAssertNotEqual(output.status, 0, output.stderr)
            XCTAssertTrue(output.stderr.contains("'--verify' rebuilds the project after writing the fixes, but the build is skipped"), output.stderr)
            XCTAssertEqual(try read("Sources/Lib/Lib.swift"), Self.library)
        }

        let withoutApply = try run(["fix", "--verify"])
        XCTAssertNotEqual(withoutApply.status, 0)
        XCTAssertTrue(withoutApply.stderr.contains("it requires '--apply'"), withoutApply.stderr)
    }

    // MARK: - Aggressive

    func testAggressiveAddsFinalOnlyWithTheFlagAndTheOpenFinalAnalysis() throws {
        try write("final class Done {}\n\nclass Box {\n    let value = 1\n}\n", to: "Sources/App/Box.swift")
        try write("import Lib\n\nprint(Widget().render(width: 1, 2) + Box().value, Done())\n", to: "Sources/App/main.swift")
        try commitAll()

        let aggressive = try run(["fix", "--aggressive", "--rule", "missing-final", "--enable-open-final-analysis", "--variants", "auto"])
        XCTAssertEqual(aggressive.status, 0, aggressive.stderr)
        XCTAssertTrue(aggressive.stdout.contains("-class Box {\n+final class Box {"), aggressive.stdout)
        XCTAssertFalse(aggressive.stdout.contains("+final final class Done"), aggressive.stdout)
        XCTAssertTrue(aggressive.stderr.contains("Would apply 1 fix in 1 file, skipped 0.\n  missing-final: 1"), aggressive.stderr)

        let tierOne = try run(["fix", "--enable-open-final-analysis"])
        XCTAssertEqual(tierOne.status, 0, tierOne.stderr)
        XCTAssertFalse(tierOne.stdout.contains("final class Box"), tierOne.stdout)

        let analysisDisabled = try run(["fix", "--aggressive"])
        XCTAssertEqual(analysisDisabled.status, 0, analysisDisabled.stderr)
        XCTAssertFalse(analysisDisabled.stdout.contains("final class Box"), analysisDisabled.stdout)

        let ruleWithoutFlag = try run(["fix", "--rule", "missing-final"])
        XCTAssertNotEqual(ruleWithoutFlag.status, 0)
        XCTAssertTrue(ruleWithoutFlag.stderr.contains("'missing-final' is a tier-2 rule, it requires '--aggressive'"), ruleWithoutFlag.stderr)
    }

    // MARK: - Private

    private static let box = "class Box {\n    let value = 1\n}\n\npublic func boxValue() -> Int { Box().value }\n"

    /// A class of the library that only a mock of the tests subclasses.
    private func writeMockedBox() throws {
        try write("""
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Fixture", targets: [
            .target(name: "Helpers"),
            .target(name: "Lib", dependencies: ["Helpers"]),
            .executableTarget(name: "App", dependencies: ["Lib"]),
            .testTarget(name: "LibTests", dependencies: ["Lib"]),
        ])
        """, to: "Package.swift")
        try write(Self.box, to: "Sources/Lib/Box.swift")
        try write("@testable import Lib\n\nfinal class BoxMock: Box {}\n", to: "Tests/LibTests/BoxMock.swift")
        try commitAll()
    }

    private struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func write(_ text: String, to path: String) throws {
        let url = package.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: package.appendingPathComponent(path), encoding: .utf8)
    }

    private func commitAll() throws {
        try git("add", "-A")
        try git("-c", "user.name=fixture", "-c", "user.email=fixture@example.com", "commit", "-q", "-m", "fixture")
    }

    private func git(_ arguments: String...) throws {
        let output = try execute(URL(fileURLWithPath: "/usr/bin/env"), ["git"] + arguments)
        XCTAssertEqual(output.status, 0, "git \(arguments.joined(separator: " ")): \(output.stderr)")
    }

    private func run(_ arguments: [String]) throws -> Output {
        try execute(locatePeripheryExecutable(near: Self.self), arguments + Self.options)
    }

    private func execute(_ executable: URL, _ arguments: [String]) throws -> Output {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("outskirts-fix-e2e-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutFile = directory.appendingPathComponent("stdout")
        let stderrFile = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
        FileManager.default.createFile(atPath: stderrFile.path, contents: nil)

        let exited = DispatchSemaphore(value: 0)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = package
        process.standardOutput = try FileHandle(forWritingTo: stdoutFile)
        process.standardError = try FileHandle(forWritingTo: stderrFile)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        if exited.wait(timeout: .now() + 300) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            XCTFail("\(executable.lastPathComponent) did not exit within 300s")
        }

        return try Output(
            status: process.terminationStatus,
            stdout: String(contentsOf: stdoutFile, encoding: .utf8),
            stderr: String(contentsOf: stderrFile, encoding: .utf8)
        )
    }
}
