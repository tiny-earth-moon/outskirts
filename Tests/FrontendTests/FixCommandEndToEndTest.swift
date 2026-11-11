#if os(macOS)
    import Foundation
    @testable import TestShared
    import XCTest

    /// Runs `outskirts fix` on a small package with two String Catalogs in a git repository.
    final class FixCommandEndToEndTest: XCTestCase {
        private static let source = """
        import Foundation

        public func greeting() -> String {
            String(localized: "used_key", bundle: .module) + String(localized: "other_used_key", table: "Other", bundle: .module)
        }

        """

        private static let localizable = catalog(["unused_key", "used_key"])
        private static let other = catalog(["other_unused_key", "other_used_key"])

        /// Every test runs in the same directory: SwiftPM and the index store record absolute paths, so a copy of the
        /// reference build only rebuilds incrementally where it was built.
        private static let root = uniqueTemporaryURL("outskirts-fix-e2e")
        private static var reference: URL {
            root.appendingPathComponent("reference")
        }

        private var package: URL {
            Self.root.appendingPathComponent("package")
        }

        private var outputDirectory: URL {
            Self.root.appendingPathComponent("output")
        }

        // swiftlint:disable:next static_over_final_class
        override class func tearDown() {
            try? FileManager.default.removeItem(at: root)
            super.tearDown()
        }

        override func setUpWithError() throws {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: package.path) {
                try fileManager.removeItem(at: package)
            }
            if fileManager.fileExists(atPath: Self.reference.path) {
                try fileManager.copyItem(at: Self.reference, to: package)
                return
            }

            try write("""
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "Fixture", defaultLocalization: "en", platforms: [.macOS(.v13)], targets: [
                .target(name: "Kit", resources: [.process("Localizable.xcstrings"), .process("Other.xcstrings")]),
            ])
            """, to: "Package.swift")
            try write(Self.source, to: "Sources/Kit/Kit.swift")
            try write(Self.localizable, to: "Sources/Kit/Localizable.xcstrings")
            try write(Self.other, to: "Sources/Kit/Other.xcstrings")
            try write(".build/\n", to: ".gitignore")
            try git("init", "-q")
            try commitAll()
            let build = try run(["fix"])
            XCTAssertEqual(build.status, 0, build.stderr)
            try fileManager.copyItem(at: package, to: Self.reference)
        }

        func testDryRunPrintsTheDiffAndWritesNothing() throws {
            let dryRun = try run(["fix"])

            XCTAssertEqual(dryRun.status, 0, dryRun.stderr)
            XCTAssertEqual(dryRun.stdout, Self.diff(removing: "unused_key", keeping: "used_key", in: "Localizable") + Self.diff(removing: "other_unused_key", keeping: "other_used_key", in: "Other"))
            XCTAssertTrue(dryRun.stderr.contains("Would remove 2 unused String Catalog keys in 2 files, skipped 0 keys."), dryRun.stderr)
            XCTAssertEqual(try read("Sources/Kit/Localizable.xcstrings"), Self.localizable)
            XCTAssertEqual(try read("Sources/Kit/Other.xcstrings"), Self.other)
        }

        func testApplyRemovesExactlyTheUnusedKeys() throws {
            let applied = try run(["fix", "--apply"])

            XCTAssertEqual(applied.status, 0, applied.stderr)
            XCTAssertEqual(applied.stdout, "")
            XCTAssertTrue(applied.stderr.contains("Removed 2 unused String Catalog keys in 2 files, skipped 0 keys."), applied.stderr)
            XCTAssertEqual(try read("Sources/Kit/Localizable.xcstrings"), Self.catalog(["used_key"]))
            XCTAssertEqual(try read("Sources/Kit/Other.xcstrings"), Self.catalog(["other_used_key"]))
            let decoded = try JSONSerialization.jsonObject(with: Data(read("Sources/Kit/Localizable.xcstrings").utf8)) as? [String: Any]
            XCTAssertEqual((decoded?["strings"] as? [String: Any]).map { Array($0.keys) }, ["used_key"])
        }

        func testKeysSuppressedByTheBaselineAreKept() throws {
            let baseline = outputDirectory.appendingPathComponent("baseline.json").path
            let written = try run(["scan", "--write-baseline", baseline])
            XCTAssertEqual(written.status, 0, written.stderr)
            try write(Self.catalog(["new_unused_key", "unused_key", "used_key"]), to: "Sources/Kit/Localizable.xcstrings")
            try commitAll()

            let dryRun = try run(["fix", "--baseline", baseline])

            XCTAssertEqual(dryRun.status, 0, dryRun.stderr)
            XCTAssertTrue(dryRun.stdout.contains("-    \"new_unused_key\" : {"), dryRun.stdout)
            XCTAssertFalse(dryRun.stdout.contains("-    \"unused_key\""), dryRun.stdout)
            XCTAssertFalse(dryRun.stdout.contains("Other.xcstrings"), dryRun.stdout)
            XCTAssertTrue(dryRun.stderr.contains("Would remove 1 unused String Catalog key in 1 file"), dryRun.stderr)
        }

        func testCatalogWithUncommittedChangesIsSkippedUnlessAllowDirty() throws {
            let dirty = Self.catalog(["unused_key", "used_key", "uncommitted_key"])
            try write(dirty, to: "Sources/Kit/Localizable.xcstrings")

            let refused = try run(["fix", "--apply"])

            XCTAssertEqual(refused.status, 0, refused.stderr)
            XCTAssertTrue(refused.stderr.contains("Removed 1 unused String Catalog key in 1 file, skipped 2 keys."), refused.stderr)
            XCTAssertTrue(refused.stderr.contains("Sources/Kit/Localizable.xcstrings: uncommitted changes, use --allow-dirty"), refused.stderr)
            XCTAssertEqual(try read("Sources/Kit/Localizable.xcstrings"), dirty)
            XCTAssertEqual(try read("Sources/Kit/Other.xcstrings"), Self.catalog(["other_used_key"]))

            let accepted = try run(["fix", "--apply", "--allow-dirty"])

            XCTAssertEqual(accepted.status, 0, accepted.stderr)
            XCTAssertEqual(try read("Sources/Kit/Localizable.xcstrings"), Self.catalog(["used_key"]))
        }

        func testIncludeRestrictsTheFixedCatalogs() throws {
            let dryRun = try run(["fix", "--include", "**/Other.xcstrings"])

            XCTAssertEqual(dryRun.status, 0, dryRun.stderr)
            XCTAssertEqual(dryRun.stdout, Self.diff(removing: "other_unused_key", keeping: "other_used_key", in: "Other"))
        }

        func testDisabledLocalizedStringAnalysisIsRefused() throws {
            let refused = try run(["fix", "--apply", "--disable-unused-localized-string-analysis"])

            XCTAssertNotEqual(refused.status, 0)
            XCTAssertTrue(refused.stderr.contains("the unused localized string analysis is disabled (disable_unused_localized_string_analysis)"), refused.stderr)
            XCTAssertFalse(refused.stderr.contains("Building"), "refused before the build:\n\(refused.stderr)")
            XCTAssertEqual(try read("Sources/Kit/Localizable.xcstrings"), Self.localizable)
        }

        func testPartialScanIsRefusedUnlessAllowed() throws {
            let refused = try run(["fix", "--apply", "--exclude-tests"])

            XCTAssertNotEqual(refused.status, 0)
            XCTAssertTrue(refused.stderr.contains("'exclude_tests' leaves code out of the scan"), refused.stderr)
            XCTAssertTrue(refused.stderr.contains("Pass '--allow-partial-scan' to accept this."), refused.stderr)
            XCTAssertEqual(try read("Sources/Kit/Localizable.xcstrings"), Self.localizable)

            let allowed = try run(["fix", "--apply", "--exclude-tests", "--allow-partial-scan"])

            XCTAssertEqual(allowed.status, 0, allowed.stderr)
            XCTAssertEqual(try read("Sources/Kit/Localizable.xcstrings"), Self.catalog(["used_key"]))
        }

        func testRuntimeKeysWithoutPrefixRefuseApplyUnlessAllowed() throws {
            try write("""
            import Foundation

            public func title(for key: String) -> String {
                Bundle.module.localizedString(forKey: key, value: nil, table: nil)
            }

            """, to: "Sources/Kit/Titles.swift")
            try commitAll()

            let dryRun = try run(["fix"])
            XCTAssertEqual(dryRun.status, 0, dryRun.stderr)
            XCTAssertTrue(dryRun.stdout.hasPrefix("--- a/Sources/Kit/Localizable.xcstrings\n"), dryRun.stdout)
            XCTAssertTrue(dryRun.stderr.contains("Titles.swift:4:"), dryRun.stderr)
            XCTAssertTrue(dryRun.stderr.contains("pass '--allow-runtime-keys'"), dryRun.stderr)

            let refused = try run(["fix", "--apply"])
            XCTAssertNotEqual(refused.status, 0)
            XCTAssertTrue(refused.stderr.contains("'--apply' could remove keys in use"), refused.stderr)
            XCTAssertEqual(try read("Sources/Kit/Localizable.xcstrings"), Self.localizable)

            let declared = try run(["fix", "--localized-string-key-patterns", "title_*"])
            XCTAssertEqual(declared.status, 0, declared.stderr)
            XCTAssertFalse(declared.stderr.contains("pass '--allow-runtime-keys'"), declared.stderr)

            let allowed = try run(["fix", "--apply", "--allow-runtime-keys"])
            XCTAssertEqual(allowed.status, 0, allowed.stderr)
            XCTAssertEqual(try read("Sources/Kit/Localizable.xcstrings"), Self.catalog(["used_key"]))
        }

        // MARK: - Private

        /// A catalog as Xcode writes it, with an empty entry per key.
        private static func catalog(_ keys: [String]) -> String {
            let entries = keys.sorted().map { "    \"\($0)\" : {\n\n    }" }.joined(separator: ",\n")
            return "{\n  \"sourceLanguage\" : \"en\",\n  \"strings\" : {\n\(entries)\n  },\n  \"version\" : \"1.0\"\n}\n"
        }

        /// The diff that removes the first of the two keys of a catalog.
        private static func diff(removing removed: String, keeping kept: String, in name: String) -> String {
            [
                "--- a/Sources/Kit/\(name).xcstrings",
                "+++ b/Sources/Kit/\(name).xcstrings",
                "@@ -1,9 +1,6 @@",
                " {",
                "   \"sourceLanguage\" : \"en\",",
                "   \"strings\" : {",
                "-    \"\(removed)\" : {",
                "-",
                "-    },",
                "     \"\(kept)\" : {",
                " ",
                "     }",
            ].map { $0 + "\n" }.joined()
        }

        private struct Output {
            let status: Int32
            let stdout: String
            let stderr: String
        }

        private func run(_ arguments: [String]) throws -> Output {
            let output = try runCapturingOutput(
                locatePeripheryExecutable(near: Self.self),
                arguments + ["--disable-update-check"],
                currentDirectoryURL: package,
                outputDirectory: outputDirectory,
                timeout: (600, "outskirts")
            )
            return Output(status: output.status, stdout: String(bytes: output.stdout, encoding: .utf8) ?? "", stderr: String(bytes: output.stderr, encoding: .utf8) ?? "")
        }

        private func write(_ contents: String, to path: String) throws {
            let url = package.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        private func read(_ path: String) throws -> String {
            try String(contentsOf: package.appendingPathComponent(path), encoding: .utf8)
        }

        private func commitAll() throws {
            try git("add", "-A")
            try git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit", "-q", "--no-gpg-sign", "-m", "fixture")
        }

        private func git(_ arguments: String...) throws {
            let output = try runCapturingOutput(URL(fileURLWithPath: "/usr/bin/env"), ["git", "-C", package.path] + arguments, outputDirectory: outputDirectory)
            XCTAssertEqual(output.status, 0, String(bytes: output.stderr, encoding: .utf8) ?? "")
        }
    }
#endif
