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

    func libraryOnly() -> Int { 3 }

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
        XCTAssertTrue(dryRun.stderr.contains("Would apply 7 fixes in 1 file, skipped 0."), dryRun.stderr)
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

        let output = try run(["fix", "--apply", "--verify", "--index-exclude", "Sources/App/Excluded.swift"])

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

        let aggressive = try run(["fix", "--aggressive", "--rule", "missing-final", "--enable-open-final-analysis"])
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

    // MARK: - Unused

    private static let deadCode = """
    struct DeadType {
        func deadMember() -> Int { 1 }
    }

    extension DeadType {
        func deadExtensionMember() {}
    }

    func deadFunction() -> Int { 2 }

    """

    func testUnusedRuleIsRefusedAfterASingleVariantScan() throws {
        try write(Self.deadCode, to: "Sources/Lib/Dead.swift")
        try commitAll()

        let refused = try run(["fix", "--rule", "unused", "--apply"])
        XCTAssertNotEqual(refused.status, 0)
        XCTAssertTrue(refused.stderr.contains("'--rule unused' removes declarations, which is only safe once every variant that ships is scanned"), refused.stderr)
        XCTAssertEqual(try read("Sources/Lib/Dead.swift"), Self.deadCode)

        let defaultRules = try run(["fix", "--variants", "auto"])
        XCTAssertEqual(defaultRules.status, 0, defaultRules.stderr)
        XCTAssertFalse(defaultRules.stdout.contains("DeadType"), defaultRules.stdout)
        XCTAssertTrue(refused.stderr.contains("or pass '--allow-partial-scan'."), refused.stderr)

        let removedFlag = try run(["fix", "--rule", "unused", "--allow-partial-variants"])
        XCTAssertNotEqual(removedFlag.status, 0)
        XCTAssertTrue(removedFlag.stderr.contains("--allow-partial-variants"), removedFlag.stderr)
    }

    func testUnusedRuleRemovesATypeWithItsExtensionAfterAScanOfEveryVariant() throws {
        try write(Self.deadCode, to: "Sources/Lib/Dead.swift")
        let releaseOnly = "func releaseOnly() -> Int { 3 }\n"
        try write(releaseOnly, to: "Sources/App/Release.swift")
        try write("import Lib\n\nprint(Widget().render(width: 1, 2))\n#if !DEBUG\n    print(releaseOnly())\n#endif\n", to: "Sources/App/main.swift")
        try commitAll()

        let output = try run(["fix", "--rule", "unused", "--variants", "auto", "--apply", "--verify"])

        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertTrue(output.stderr.contains("Applied 3 fixes in 1 file, skipped 2.\n"), output.stderr)
        XCTAssertTrue(output.stderr.contains("  removed unused 'DeadType' at Sources/Lib/Dead.swift:1:8 [p2_"), output.stderr)
        // Only a release build calls it, which a debug scan does not see.
        XCTAssertTrue(output.stderr.contains("  skipped unused 'releaseOnly()' at Sources/App/Release.swift:1:6: name written in an #if clause that no scanned build compiled"), output.stderr)
        XCTAssertTrue(output.stderr.contains("  skipped unused 'helperValue()' at Sources/Helpers/Helpers.swift:1:13: public API, use --include-public"), output.stderr)
        XCTAssertTrue(output.stderr.contains("The project builds with the fixes."), output.stderr)
        XCTAssertEqual(try read("Sources/Lib/Dead.swift"), "")
        XCTAssertEqual(try read("Sources/App/Release.swift"), releaseOnly)
        XCTAssertEqual(try read("Sources/Lib/Lib.swift"), Self.library)
    }

    func testUnusedRuleIsRefusedWhenAnOptionLeavesCodeOutOfTheScan() throws {
        for (option, key) in [
            (["--index-exclude", "Sources/App/**"], "index_exclude"),
            (["--exclude-tests"], "exclude_tests"),
            (["--exclude-targets", "App"], "exclude_targets"),
        ] {
            let refused = try run(["fix", "--rule", "unused", "--variants", "auto"] + option)
            XCTAssertNotEqual(refused.status, 0)
            XCTAssertTrue(refused.stderr.contains("but '\(key)' leaves code out of the scan"), refused.stderr)
        }

        let flagWithoutRule = try run(["fix", "--allow-partial-scan"])
        XCTAssertNotEqual(flagWithoutRule.status, 0)
        XCTAssertTrue(flagWithoutRule.stderr.contains("'--allow-partial-scan' only applies to '--rule unused'"), flagWithoutRule.stderr)
    }

    func testUnusedRuleKeepsTheFilesOfALocalDependencyPackage() throws {
        try write("""
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Core", products: [.library(name: "Core", targets: ["Core"])], targets: [
            .target(name: "Core"),
            .testTarget(name: "CoreTests", dependencies: ["Core"]),
        ])
        """, to: "Modules/Core/Package.swift")
        let core = "public func coreValue() -> Int { 1 }\nfunc coreHelperForTests() -> Int { 2 }\n"
        try write(core, to: "Modules/Core/Sources/Core/Core.swift")
        try write("@testable import Core\nimport XCTest\n\nfinal class CoreTests: XCTestCase {\n    func testHelper() { XCTAssertEqual(coreHelperForTests(), 2) }\n}\n", to: "Modules/Core/Tests/CoreTests/CoreTests.swift")
        try write("""
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Fixture", dependencies: [.package(path: "Modules/Core")], targets: [
            .target(name: "Helpers"),
            .target(name: "Lib", dependencies: ["Helpers"]),
            .executableTarget(name: "App", dependencies: ["Lib", .product(name: "Core", package: "Core")]),
        ])
        """, to: "Package.swift")
        try write("import Core\nimport Lib\n\nprint(Widget().render(width: 1, 2), coreValue())\n", to: "Sources/App/main.swift")
        try commitAll()

        let output = try run(["fix", "--rule", "unused", "--variants", "auto"])

        XCTAssertEqual(output.status, 0, output.stderr)
        // The tests of the dependency use it, but only the root package is built.
        XCTAssertTrue(output.stderr.contains("  skipped unused 'coreHelperForTests()' at Modules/Core/Sources/Core/Core.swift:2:6: dependency package"), output.stderr)
        XCTAssertFalse(output.stdout.contains("coreHelperForTests"), output.stdout)
    }

    // MARK: - Iterate

    /// The helper is only called in a release clause of the dead type, so the first pass keeps it.
    private static let cascade = """
    struct DeadType {
        func deadMember() -> Int {
            #if !DEBUG
                deadHelper()
            #else
                1
            #endif
        }
    }

    extension DeadType {
        func deadExtensionMember() {}
    }

    func deadHelper() -> Int { 2 }

    """

    private static let iterate = ["fix", "--rule", "unused", "--variants", "auto", "--apply", "--iterate"]

    func testIterateRemovesACascadeInTwoPassesAndStopsWhenNothingIsLeft() throws {
        try write(Self.cascade, to: "Sources/Lib/Dead.swift")
        try commitAll()

        let output = try run(Self.iterate)

        XCTAssertEqual(output.status, 0, output.stderr)
        let passes = output.stderr.components(separatedBy: "Pass ").dropFirst().map { "Pass " + $0 }
        XCTAssertEqual(passes.count, 3, output.stderr)
        guard passes.count == 3 else { return }

        // The file written by the first pass has uncommitted changes, which the second pass may still edit.
        XCTAssertTrue(passes[0].hasPrefix("Pass 1 of at most 5:"), passes[0])
        XCTAssertTrue(passes[0].contains("\nApplied 2 fixes in 1 file, skipped 2.\n"), passes[0])
        XCTAssertTrue(passes[0].contains("  skipped unused 'deadHelper()' at Sources/Lib/Dead.swift:15:6: name written in an #if clause"), passes[0])
        XCTAssertTrue(passes[0].contains("The project builds with the fixes."), passes[0])
        XCTAssertTrue(passes[1].hasPrefix("Pass 2 of at most 5:"), passes[1])
        XCTAssertTrue(passes[1].contains("\nApplied 1 fix in 1 file, skipped 1.\n"), passes[1])
        XCTAssertTrue(passes[1].contains("  removed unused 'deadHelper()' at Sources/Lib/Dead.swift:1:6 [p2_"), passes[1])
        XCTAssertTrue(passes[1].contains("The project builds with the fixes."), passes[1])
        XCTAssertTrue(passes[2].hasPrefix("Pass 3 of at most 5:"), passes[2])
        XCTAssertTrue(passes[2].contains("\nApplied 0 fixes in 0 files, skipped 1.\n"), passes[2])
        XCTAssertTrue(passes[2].contains("Nothing left to fix after 3 passes: 3 fixes in 1 file."), passes[2])
        XCTAssertEqual(try read("Sources/Lib/Dead.swift"), "")
        XCTAssertEqual(try read("Sources/Lib/Lib.swift"), Self.library)
    }

    func testIterateStopsAtTheLimitOfPasses() throws {
        // Each helper is only called in a release clause of the previous one, so each pass frees one more.
        let chain = (1 ... 6).map { level in
            "func chain\(level)() -> Int {\n    #if !DEBUG\n        chain\(level + 1)()\n    #else\n        0\n    #endif\n}\n"
        }
        try write(Self.cascade.replacingOccurrences(of: "deadHelper()\n", with: "chain1()\n") + chain.joined(separator: "\n") + "\nfunc chain7() -> Int { 7 }\n", to: "Sources/Lib/Dead.swift")
        try commitAll()

        let output = try run(Self.iterate)

        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertTrue(output.stderr.contains("Pass 5 of at most 5:\n"), output.stderr)
        XCTAssertFalse(output.stderr.contains("Pass 6"), output.stderr)
        // Without '--verify', every pass is still rebuilt before the next one.
        XCTAssertEqual(output.stderr.components(separatedBy: "The project builds with the fixes.").count - 1, 5, output.stderr)
        XCTAssertTrue(output.stderr.contains("Stopped at the limit of 5 passes: 7 fixes in 1 file. The last pass still fixed something: run the command again to fix what it left."), output.stderr)
        let fixed = try read("Sources/Lib/Dead.swift")
        XCTAssertFalse(fixed.contains("DeadType"), fixed)
        XCTAssertFalse(fixed.contains("func chain4()"), fixed)
        XCTAssertTrue(fixed.contains("func chain5() -> Int {"), fixed)
    }

    func testIterateUndoesOnlyThePassWhoseVerificationFails() throws {
        try write(Self.cascade, to: "Sources/Lib/Dead.swift")
        // The only other caller of the helper is excluded from the index, so the second pass removes it.
        try write("func excludedClient() -> Int { deadHelper() }\n", to: "Sources/Lib/Excluded.swift")
        try commitAll()

        let output = try run(Self.iterate + ["--index-exclude", "Sources/Lib/Excluded.swift", "--allow-partial-scan"])

        XCTAssertNotEqual(output.status, 0, output.stderr)
        XCTAssertTrue(output.stderr.contains("Pass 1 of at most 5:\n"), output.stderr)
        XCTAssertTrue(output.stderr.contains("\nApplied 2 fixes in 1 file"), output.stderr)
        XCTAssertTrue(output.stderr.contains("Pass 2 of at most 5:\n"), output.stderr)
        XCTAssertTrue(output.stderr.contains("\nApplied 1 fix in 1 file"), output.stderr)
        XCTAssertTrue(output.stderr.contains("The build failed after the fixes were applied"), output.stderr)
        XCTAssertTrue(output.stderr.contains("The fixes break the build, restored 1 of 1 file:\n  restored Sources/Lib/Dead.swift\nPass 2 is undone. The fixes of pass 1 are kept: 2 fixes in 1 file."), output.stderr)
        XCTAssertFalse(output.stderr.contains("Pass 3"), output.stderr)
        let kept = try read("Sources/Lib/Dead.swift")
        XCTAssertFalse(kept.contains("DeadType"), kept)
        XCTAssertTrue(kept.contains("func deadHelper() -> Int { 2 }"), kept)
    }

    func testIterateOptionsAreRefusedOutsideTheirScope() throws {
        for (arguments, message) in [
            (["--rule", "unused", "--iterate"], "'--iterate' scans again the files that each pass wrote, it requires '--apply'"),
            (["--apply", "--iterate"], "'--iterate' only applies to '--rule unused'"),
            // '--iterate' verifies every pass, so it needs a build it can run again.
            (["--rule", "unused", "--apply", "--iterate", "--skip-build"], "'--iterate' rebuilds the project after each pass, but the build is skipped"),
        ] {
            let refused = try run(["fix"] + arguments)
            XCTAssertNotEqual(refused.status, 0, arguments.joined(separator: " "))
            XCTAssertTrue(refused.stderr.contains(message), refused.stderr)
        }
    }

    /// The macOS + iOS package whose code is only used under `#if os(iOS)` still builds for both platforms.
    func testIterateKeepsTheMultiVariantPackageBuildingOnEveryPlatform() throws {
        let sdk = try execute(URL(fileURLWithPath: "/usr/bin/env"), ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"])
        try XCTSkipIf(sdk.status != 0, "The iOS simulator SDK is not installed: \(sdk.stderr)")

        try FileManager.default.removeItem(at: package)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: ProjectRootPath.appending("Tests/SPMTests/SPMProjectMultiVariant").string),
            to: package
        )
        let copiedBuild = package.appendingPathComponent(".build")
        if FileManager.default.fileExists(atPath: copiedBuild.path) {
            try FileManager.default.removeItem(at: copiedBuild)
        }
        try write(".build/\n", to: ".gitignore")
        try git("init", "-q")
        try commitAll()

        let output = try run(Self.iterate)

        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertTrue(output.stderr.contains("  removed unused 'phoneNeverCalled()' at Sources/Kit/InBlock.swift:2:10 [p2_"), output.stderr)
        XCTAssertTrue(output.stderr.contains("Nothing left to fix after"), output.stderr)
        let inBlock = try read("Sources/Kit/InBlock.swift")
        XCTAssertFalse(inBlock.contains("phoneNeverCalled"), inBlock)
        XCTAssertTrue(inBlock.contains("func phoneCalled()"), inBlock)
        XCTAssertTrue(try read("Sources/Kit/SameName.swift").contains("struct Alpha {\n    func draw()"))
        XCTAssertTrue(try read("Sources/Kit/ImportOnly.swift").hasPrefix("import Util\n"))

        let sdkPath = sdk.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        for arguments in [[], ["--triple", "arm64-apple-ios18.0-simulator", "--sdk", sdkPath]] {
            let scratch = package.appendingPathComponent(".build/check-\(arguments.isEmpty ? "macos" : "ios")").path
            let build = try execute(URL(fileURLWithPath: "/usr/bin/env"), ["swift", "build", "--package-path", package.path, "--scratch-path", scratch] + arguments)
            XCTAssertEqual(build.status, 0, "swift build \(arguments.joined(separator: " ")):\n\(build.stdout.suffix(2000))\n\(build.stderr.suffix(2000))")
        }
    }

    // MARK: - Private

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
