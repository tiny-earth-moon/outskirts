import ArgumentParser
import Configuration
import Foundation
@testable import Frontend
import Shared
@testable import TestShared
import XCTest

final class CommandLinePrecedenceTest: XCTestCase {
    private typealias BooleanSetting = (key: String, keyPath: KeyPath<Configuration, Bool>)

    private static let booleanSettings: [BooleanSetting] = [
        ("exclude_tests", \.excludeTests),
        ("retain_public", \.retainPublic),
        ("disable_platform_conditional_retention", \.disablePlatformConditionalRetention),
        ("disable_redundant_public_analysis", \.disableRedundantPublicAnalysis),
        ("enable_redundant_public_members", \.enableRedundantPublicMembers),
        ("enable_open_final_analysis", \.enableOpenFinalAnalysis),
        ("enable_empty_extension_analysis", \.enableEmptyExtensionAnalysis),
        ("enable_redundant_access_level_analysis", \.enableRedundantAccessLevelAnalysis),
        ("report_unused_type_parameters", \.reportUnusedTypeParameters),
        ("disable_unused_import_analysis", \.disableUnusedImportAnalysis),
        ("enable_unused_system_imports", \.enableUnusedSystemImports),
        ("superfluous_ignore_comments", \.superfluousIgnoreComments),
        ("disable_unused_localized_string_analysis", \.disableUnusedLocalizedStringAnalysis),
        ("localized_string_key_literal_match", \.localizedStringKeyLiteralMatch),
        ("retain_runtime_localized_keys", \.retainRuntimeLocalizedKeys),
        ("retain_assign_only_properties", \.retainAssignOnlyProperties),
        ("enable_unassigned_optional_analysis", \.enableUnassignedOptionalAnalysis),
        ("enable_unconstructed_enum_case_analysis", \.enableUnconstructedEnumCaseAnalysis),
        ("retain_objc_accessible", \.retainObjcAccessible),
        ("retain_js_accessible", \.retainJsAccessible),
        ("retain_objc_annotated", \.retainObjcAnnotated),
        ("retain_unused_protocol_func_params", \.retainUnusedProtocolFuncParams),
        ("retain_unused_parameters_without_default", \.retainUnusedParametersWithoutDefault),
        ("retain_swift_ui_previews", \.retainSwiftUIPreviews),
        ("retain_codable_properties", \.retainCodableProperties),
        ("retain_encodable_properties", \.retainEncodableProperties),
        ("retain_equatable_properties", \.retainEquatableProperties),
        ("retain_hashable_properties", \.retainHashableProperties),
        ("clean_build", \.cleanBuild),
        ("skip_build", \.skipBuild),
        ("strict_index", \.strictIndex),
        ("skip_schemes_validation", \.skipSchemesValidation),
        ("relative_results", \.relativeResults),
        ("strict", \.strict),
        ("disable_update_check", \.disableUpdateCheck),
        ("verbose", \.verbose),
        ("quiet", \.quiet),
        ("retain_synthesized_uses", \.retainSynthesizedUses),
        ("detect_unused_asset_catalog_colors", \.detectUnusedAssetCatalogColors),
        ("detect_unused_asset_catalog_images", \.detectUnusedAssetCatalogImages),
    ]

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("periphery-precedence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testFormatOnTheCommandLineOverridesTheFileEvenWhenItIsTheDefault() throws {
        let configuration = try merge(["--format", "xcode"], file: "format: json\n")

        XCTAssertEqual(configuration.outputFormat, .xcode)
    }

    func testFormatOnTheCommandLineOverridesTheFile() throws {
        let configuration = try merge(["--format", "csv"], file: "format: json\n")

        XCTAssertEqual(configuration.outputFormat, .csv)
    }

    func testRelativeToOnTheCommandLineOverridesTheFile() throws {
        let configuration = try merge(["--relative-to", "/repo"], file: "relative_results_base: /other\n")

        XCTAssertEqual(configuration.relativeResultsBase?.string, "/repo")
    }

    func testRelativeResultsBaseFromTheFile_isKeptWhenTheOptionIsNotPassed() throws {
        let configuration = try merge([], file: "relative_results_base: /other\n")

        XCTAssertEqual(configuration.relativeResultsBase?.string, "/other")
    }

    func testChangedSinceOnTheCommandLineOverridesTheFile() throws {
        let configuration = try merge(["--changed-since", "origin/main", "--changed-lines"], file: "changed_since: develop\nchanged_lines: false\n")

        XCTAssertEqual(configuration.changedSince, "origin/main")
        XCTAssertTrue(configuration.changedLines)
    }

    func testChangedSinceFromTheFile_isKeptWhenTheOptionIsNotPassed() throws {
        let configuration = try merge([], file: "changed_since: develop\nchanged_lines: true\n")

        XCTAssertEqual(configuration.changedSince, "develop")
        XCTAssertTrue(configuration.changedLines)
    }

    func testNoStrictOverridesTheFile() throws {
        let configuration = try merge(["--no-strict"], file: "strict: true\n")

        XCTAssertFalse(configuration.strict)
    }

    func testOptionsThatAreNotPassedLeaveTheFileValuesUntouched() throws {
        let configuration = try merge([], file: """
        format: json
        strict: true
        relative_results: true
        superfluous_ignore_comments: false
        color: never
        cache_max_age_days: 3
        schemes: [App]
        index_exclude: ["**/Vendor/**"]
        localized_string_catalog_exclude: ["**/Other.xcstrings"]
        project: App.xcodeproj
        index_store_path: [.build/out]
        report_exclude: ["**/Generated/**"]
        """)

        XCTAssertEqual(configuration.outputFormat, .json)
        XCTAssertTrue(configuration.strict)
        XCTAssertTrue(configuration.relativeResults)
        XCTAssertFalse(configuration.superfluousIgnoreComments)
        XCTAssertEqual(configuration.color, .never)
        XCTAssertEqual(configuration.cacheMaxAgeDays, 3)
        XCTAssertEqual(configuration.schemes, ["App"])
        XCTAssertTrue(configuration.indexExclude.contains("**/Vendor/**"))
        XCTAssertEqual(configuration.localizedStringCatalogExclude, ["**/Other.xcstrings"])
        XCTAssertEqual(configuration.project?.string, "App.xcodeproj")
        XCTAssertEqual(configuration.indexStorePath.map(\.string), [".build/out"])
        XCTAssertEqual(configuration.reportExclude, [.pattern("**/Generated/**")])
    }

    func testEveryBooleanOptionHasAnInversionThatOverridesTheFile() throws {
        for (key, keyPath) in Self.booleanSettings {
            let flag = key.replacingOccurrences(of: "_", with: "-")

            for fileValue in [true, false] {
                let file = "\(key): \(fileValue)\n"

                XCTAssertEqual(try merge([], file: file)[keyPath: keyPath], fileValue, "\(key) from the file")
                XCTAssertTrue(try merge(["--\(flag)"], file: file)[keyPath: keyPath], "--\(flag) over \(file)")
                XCTAssertFalse(try merge(["--no-\(flag)"], file: file)[keyPath: keyPath], "--no-\(flag) over \(file)")
            }
        }
    }

    func testTheLastOfAFlagAndItsInversionWins() throws {
        XCTAssertTrue(try merge(["--no-strict", "--strict"], file: "").strict)
        XCTAssertFalse(try merge(["--strict", "--no-strict"], file: "strict: true\n").strict)
    }

    func testValuesEqualToTheDefaultOverrideTheFile() throws {
        let defaults = Configuration()
        let configuration = try merge(
            [
                "--color", "auto",
                "--cache-max-age-days", "14",
                "--localized-string-catalog-exclude",
            ] + defaults.localizedStringCatalogExclude,
            file: """
            color: never
            cache_max_age_days: 3
            localized_string_catalog_exclude: ["**/Other.xcstrings"]
            """
        )

        XCTAssertEqual(configuration.color, .auto)
        XCTAssertEqual(configuration.cacheMaxAgeDays, 14)
        XCTAssertEqual(configuration.localizedStringCatalogExclude, defaults.localizedStringCatalogExclude)
    }

    func testNoColorOverridesTheFile() throws {
        let configuration = try merge(["--no-color"], file: "color: always\n")

        XCTAssertEqual(configuration.color, .never)
    }

    func testListsOnTheCommandLineReplaceTheOnesOfTheFile() throws {
        let configuration = try merge(
            ["--schemes", "Tools", "--exclude-targets", "Demo", "--report-exclude", "**/Mocks/**"],
            file: """
            schemes: [App]
            exclude_targets: [Other]
            report_exclude: ["**/Generated/**"]
            """
        )

        XCTAssertEqual(configuration.schemes, ["Tools"])
        XCTAssertEqual(configuration.excludeTargets, ["Demo"])
        XCTAssertEqual(configuration.reportExclude, [.pattern("**/Mocks/**")])
    }

    func testRetainPublicModulesOnTheCommandLineReplaceTheOnesOfTheFile() throws {
        let configuration = try merge(["--retain-public-modules", "Kit"], file: "retain_public: [Lib]\n")

        XCTAssertEqual(configuration.retainPublicModules, ["Kit"])
        XCTAssertFalse(configuration.retainPublic)
    }

    func testNoRetainPublicClearsTheModulesOfTheFile() throws {
        let configuration = try merge(["--no-retain-public"], file: "retain_public: [Lib]\n")

        XCTAssertFalse(configuration.retainPublic)
        XCTAssertEqual(configuration.retainPublicModules, [])
    }

    func testRetainPublicOnTheCommandLineKeepsTheModulesOfTheFile() throws {
        let configuration = try merge(["--retain-public"], file: "retain_public_modules: [Lib]\n")

        XCTAssertTrue(configuration.retainPublic)
        XCTAssertEqual(configuration.retainPublicModules, ["Lib"])
    }

    func testPathsOnTheCommandLineOverrideTheFile() throws {
        let configuration = try merge(
            ["--project", "Cli.xcodeproj", "--baseline", "cli.json"],
            file: """
            project: File.xcodeproj
            baseline: file.json
            write_baseline: out.json
            """
        )

        XCTAssertEqual(configuration.project?.string, "Cli.xcodeproj")
        XCTAssertEqual(configuration.baseline?.string, "cli.json")
        XCTAssertEqual(configuration.writeBaseline?.string, "out.json")
    }

    func testPruneBaseline_commandLineOverridesTheFile() throws {
        XCTAssertTrue(try merge(["--prune-baseline"], file: "prune_baseline: false").pruneBaseline)
        XCTAssertFalse(try merge(["--no-prune-baseline"], file: "prune_baseline: true").pruneBaseline)
        XCTAssertTrue(try merge([], file: "prune_baseline: true").pruneBaseline)
        XCTAssertFalse(try merge([], file: nil).pruneBaseline)
    }

    func testStrictBaseline_commandLineOverridesTheFile() throws {
        XCTAssertTrue(try merge(["--strict-baseline"], file: "strict_baseline: false").strictBaseline)
        XCTAssertFalse(try merge(["--no-strict-baseline"], file: "strict_baseline: true").strictBaseline)
        XCTAssertTrue(try merge([], file: "strict_baseline: true").strictBaseline)
        XCTAssertFalse(try merge([], file: nil).strictBaseline)
    }

    func testWithoutAFileTheCommandLineAndTheDefaultsApply() throws {
        let configuration = try merge(["--strict", "--format", "json"], file: nil)

        XCTAssertTrue(configuration.strict)
        XCTAssertEqual(configuration.outputFormat, .json)
        XCTAssertFalse(configuration.quiet)
        XCTAssertEqual(configuration.color, .auto)
        XCTAssertEqual(configuration.cacheMaxAgeDays, 14)
        XCTAssertTrue(configuration.superfluousIgnoreComments)
    }

    func testRuleOptionsSetTheOptionOfTheRule() throws {
        XCTAssertTrue(try merge(["--disable-rule", "unused-import"], file: "").disableUnusedImportAnalysis)
        XCTAssertFalse(try merge(["--enable-rule", "unused-import"], file: "disable_unused_import_analysis: true\n").disableUnusedImportAnalysis)
        XCTAssertTrue(try merge(["--enable-rule", "missing-final"], file: "").enableOpenFinalAnalysis)
        XCTAssertFalse(try merge(["--disable-rule", "superfluous-ignore"], file: "").superfluousIgnoreComments)

        let configuration = try merge(["--enable-rule", "empty-extension", "--enable-rule", "unused-asset-color", "--disable-rule", "redundant-public", "--enable-rule", "unused"], file: "")
        XCTAssertTrue(configuration.isEnabled(.emptyExtension))
        XCTAssertTrue(configuration.isEnabled(.unusedAssetColor))
        XCTAssertFalse(configuration.isEnabled(.redundantPublic))
        XCTAssertTrue(configuration.isEnabled(.unused))

        let untouched = try merge([], file: "enable_empty_extension_analysis: true\n")
        XCTAssertTrue(untouched.isEnabled(.emptyExtension))
        XCTAssertTrue(untouched.isEnabled(.redundantPublic))
    }

    func testRuleOptionsRejectAContradictionAnAlwaysCheckedRuleAndAnUnknownId() {
        for arguments in [
            ["--disable-rule", "unused"],
            ["--enable-rule", "redundant-open", "--disable-rule", "missing-final"],
            ["--enable-rule", "unused-import", "--disable-rule", "unused-import"],
            ["--enable-rule", "redundant-public", "--disable-redundant-public-analysis"],
            ["--disable-rule", "empty-extension", "--enable-empty-extension-analysis"],
            ["--enable-rule", "unused-imports"],
        ] {
            XCTAssertThrowsError(try ScanCommand.parse(arguments), "\(arguments)")
        }

        XCTAssertNoThrow(try ScanCommand.parse(["--enable-rule", "redundant-public", "--no-disable-redundant-public-analysis"]))
    }

    func testListRulesPrintsEveryRuleWithItsDefaultAndKeys() throws {
        let lines = ListRulesCommand.text().split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.count, RuleIdentifier.allCases.count + 1)
        XCTAssertEqual(lines[0], "RULE                     DEFAULT  V2 KEY                         V1 KEY")
        XCTAssertEqual(lines[1], "unused                   on       rules.unused                   - (always checked)")
        XCTAssertEqual(lines[2], "unused-import            on       rules.unused-import            disable_unused_import_analysis (true turns it off)")
        XCTAssertTrue(lines.contains("missing-final            off      rules.missing-final            enable_open_final_analysis"))

        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ListRulesCommand.json().utf8)) as? [[String: Any]])
        XCTAssertEqual(rules.compactMap { $0["id"] as? String }, RuleIdentifier.allCases.map(\.rawValue))
        let unusedImport = try XCTUnwrap(rules.first { $0["id"] as? String == "unused-import" })
        XCTAssertEqual(unusedImport["v1_key"] as? String, "disable_unused_import_analysis")
        XCTAssertEqual(unusedImport["v2_key"] as? String, "rules.unused-import")
        XCTAssertEqual(Set(unusedImport.keys), ["id", "enabled_by_default", "v2_key", "v1_key", "v1_key_turns_rule_off", "overridable"])
        XCTAssertTrue(rules.first { $0["id"] as? String == "unused" }?["v1_key"] is NSNull)
    }

    func testConfigCommandsAreListed() {
        let help = ConfigCommand.helpMessage(columns: 1000)

        for subcommand in ["check", "print", "migrate", "schema"] {
            XCTAssertTrue(help.contains("  \(subcommand) "), "no '\(subcommand)' in the help")
        }
    }

    func testHelpStatesTheDefaultsThatOptionsNoLongerShow() {
        let defaults = Configuration()
        let help = ScanCommand.helpMessage()

        XCTAssertTrue(help.contains("(default: \(defaults.outputFormat.rawValue))"))
        XCTAssertTrue(help.contains("(default: \(defaults.color.rawValue))"))
        XCTAssertTrue(help.contains("(default: \(defaults.cacheMaxAgeDays))"))
        XCTAssertTrue(defaults.indexExclude.allSatisfy { help.contains($0) })
        XCTAssertTrue(defaults.localizedStringCatalogExclude.allSatisfy { help.contains($0) })
    }

    func testHelpGroupsTheScanOptionsAndShowsNoMachinePath() {
        let help = ScanCommand.helpMessage(columns: 1000)

        for title in ["PROJECT", "BUILD", "ANALYSIS", "RETENTION", "RESULTS", "BASELINE", "LOCALIZED STRINGS", "MISCELLANEOUS"] {
            XCTAssertTrue(help.contains("\n\(title):\n"), "no '\(title)' group in the help")
        }
        XCTAssertFalse(help.contains(FileManager.default.currentDirectoryPath), "the help shows the current directory")
        XCTAssertTrue(help.contains("(default: the current directory)"))
    }

    func testProjectRootDefaultsToNothingUntilTheScanRuns() throws {
        XCTAssertNil(try ScanCommand.parse([]).projectOptions.locationOptions.projectRoot)
        XCTAssertEqual(try ScanCommand.parse(["--project-root", "/tmp"]).projectOptions.locationOptions.projectRoot, "/tmp")
    }

    func testVersionOptionPrintsWhatTheVersionCommandPrints() throws {
        let option = try runOutskirts(["--version"])
        let command = try runOutskirts(["version"])

        XCTAssertEqual(option.status, 0, option.output)
        XCTAssertEqual(option.output, "\(PeripheryVersion)\n")
        XCTAssertEqual(option.output, command.output)
    }

    // MARK: - Private

    private func runOutskirts(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = try locatePeripheryExecutable(near: Self.self)
        process.arguments = arguments
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(bytes: data, encoding: .utf8) ?? "")
    }

    private func merge(_ arguments: [String], file: String?) throws -> Configuration {
        let command = try ScanCommand.parse(arguments)
        let configuration = Configuration()

        if let file {
            let path = directory.appendingPathComponent("periphery-\(UUID().uuidString).yml")
            try file.write(to: path, atomically: true, encoding: .utf8)
            try configuration.load(from: .init(path.path)) { XCTFail("Unexpected warning \($0)") }
        }

        command.apply(to: configuration)
        return configuration
    }
}
