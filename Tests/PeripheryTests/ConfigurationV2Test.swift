@testable import Configuration
import Foundation
import Shared
import SystemPackage
@testable import TestShared
import XCTest
import Yams

final class ConfigurationV2Test: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("outskirts-config-v2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Rules

    func testRuleIdentifiersAreTheOutputIds() {
        XCTAssertEqual(RuleIdentifier.allCases.map(\.rawValue), [
            "unused", "unused-import", "unused-parameter", "unused-localized-string", "unused-asset-color",
            "unused-asset-image", "assign-only-property", "unassigned-optional", "redundant-protocol",
            "redundant-conformance", "redundant-public", "redundant-open", "missing-final", "redundant-access-level",
            "empty-extension", "superfluous-ignore",
        ])
    }

    func testRuleDefaultsMatchTheDefaultConfiguration() {
        let configuration = Configuration()

        for rule in RuleIdentifier.allCases {
            XCTAssertEqual(configuration.isEnabled(rule), rule.isEnabledByDefault, rule.rawValue)
        }
    }

    func testRuleV1KeysAreBooleanSettings() {
        let keys = Set(Configuration().settingKeys)

        for rule in RuleIdentifier.allCases {
            guard let key = rule.v1Key else { continue }

            XCTAssertTrue(keys.contains(key), "\(rule.rawValue): \(key)")
        }
    }

    func testV1KeyTurnsTheRuleOnOrOff() throws {
        let configuration = try loadV1("""
        disable_unused_import_analysis: true
        enable_empty_extension_analysis: true
        """)

        XCTAssertFalse(configuration.isEnabled(.unusedImport))
        XCTAssertTrue(configuration.isEnabled(.emptyExtension))
        XCTAssertTrue(configuration.isEnabled(.unused))
    }

    // MARK: - Key mapping

    func testEveryV1KeyHasAV2Path() {
        let mapped = Set(ConfigurationKeyMapping.all.map(\.v1Key))

        XCTAssertEqual(mapped, Set(Configuration().settingKeys))
    }

    func testV2PathsSharedBySeveralV1Keys() {
        var paths: [String: [String]] = [:]
        for mapping in ConfigurationKeyMapping.all {
            paths[mapping.v2Path, default: []].append(mapping.v1Key)
        }

        // Several v1 keys share a path only when one v2 value sets them all.
        let shared = paths.filter { $0.value.count > 1 }.mapValues { $0.sorted() }
        XCTAssertEqual(shared, [
            "retain.objc": ["retain_objc_accessible", "retain_objc_annotated"],
            "retain.properties_of": ["retain_codable_properties", "retain_encodable_properties", "retain_equatable_properties", "retain_hashable_properties"],
            "retain.platform_conditional": ["disable_platform_conditional_retention", "platform_conditional_retention"],
        ])
    }

    func testFullV2FileSetsEveryMappedPath() throws {
        let model = try ConfigurationV2(yaml: Self.fullV2)

        for mapping in ConfigurationKeyMapping.all {
            guard let value = mapping.value else { continue }

            XCTAssertNotNil(value(model), mapping.v2Path)
        }
    }

    func testFullV1FileSetsEverySetting() throws {
        let configuration = try loadV1(Self.fullV1)

        for setting in configuration.settings where setting.key != "disable_platform_conditional_retention" {
            XCTAssertTrue(setting.hasNonDefaultValue, setting.key)
        }
    }

    func testV1FileAndItsV2EquivalentGiveTheSameConfiguration() throws {
        let v1 = try loadV1(Self.fullV1)
        let v2 = try loadV2(Self.fullV2)

        XCTAssertEqual(effective(v2), effective(v1))
        XCTAssertEqual(v2.resolvedPlatformConditionalRetention, v1.resolvedPlatformConditionalRetention)
    }

    func testPartialFilesGiveTheSameConfiguration() throws {
        let pairs = [
            ("retain_public: true\nretain_codable_properties: true\n", "retain: {public: true, properties_of: [Codable]}"),
            ("enable_open_final_analysis: true\nsuperfluous_ignore_comments: false\n", "rules: {redundant-open: on, missing-final: on, superfluous-ignore: off}"),
            ("format: sarif\nrelative_results: true\ndisable_update_check: true\n", "report: {format: sarif, relative: true, update_check: false}"),
            ("index_exclude: [\"**/Gen/**\"]\nexclude_tests: true\n", "exclude: {index: [\"**/Gen/**\"], tests: true}"),
            ("baseline: b.json\nstrict_baseline: true\n", "baseline: {path: b.json, strict: true}"),
            ("variants: [arm64-apple-macosx15.0]\n", "variants: [arm64-apple-macosx15.0]"),
            ("retain_objc_annotated: true\n", "retain: {objc: annotated}"),
        ]

        for (v1, v2) in pairs {
            XCTAssertEqual(effective(try loadV2("version: 2\n" + v2)), effective(try loadV1(v1)), v2)
        }
    }

    func testDisablePlatformConditionalRetentionIsTheOffValue() throws {
        let v1 = try loadV1("disable_platform_conditional_retention: true\n")
        let v2 = try loadV2("version: 2\nretain: {platform_conditional: off}\n")

        XCTAssertEqual(v1.resolvedPlatformConditionalRetention, .off)
        XCTAssertEqual(v2.resolvedPlatformConditionalRetention, .off)
    }

    // MARK: - Version 2 files

    func testVersion2FileLoads() throws {
        let configuration = try loadV2("""
        version: 2
        rules: {unused-import: off, missing-final: on, redundant-open: on}
        retain: {public: true, objc: [annotated, accessible]}
        report: {format: json, strict: true}
        """)

        XCTAssertFalse(configuration.isEnabled(.unusedImport))
        XCTAssertTrue(configuration.isEnabled(.missingFinal))
        XCTAssertTrue(configuration.retainPublic)
        XCTAssertTrue(configuration.retainObjcAnnotated)
        XCTAssertTrue(configuration.retainObjcAccessible)
        XCTAssertEqual(configuration.outputFormat, .json)
        XCTAssertTrue(configuration.strict)
    }

    func testVersion2File_writesTheVersion2Baseline() throws {
        XCTAssertEqual(try loadV2("version: 2\n").baselineFormat, .v2)
    }

    func testVersion1File_writesTheVersion1Baseline() throws {
        XCTAssertEqual(try loadV1("strict: true\n").baselineFormat, .v1)
        XCTAssertEqual(Configuration().baselineFormat, .v1)
    }

    func testVersion2FileWithOnlyTheVersionLoadsTheDefaults() throws {
        let configuration = try loadV2("version: 2\n")

        XCTAssertFalse(configuration.hasNonDefaultValues)
    }

    func testIndexDefaultsAreKeptUnlessTurnedOff() throws {
        let kept = try loadV2("version: 2\nexclude: {index: [\"**/Gen/**\"]}\n")
        let dropped = try loadV2("version: 2\nexclude: {index: [\"**/Gen/**\"], index_defaults: false}\n")

        XCTAssertEqual(Set(kept.indexExclude), Set(["**/Gen/**"] + Configuration().indexExclude))
        XCTAssertEqual(dropped.indexExclude, ["**/Gen/**"])

        dropped.apply(\.$indexExclude, ["Other/**"])
        XCTAssertEqual(dropped.indexExclude, ["Other/**"])
    }

    func testUnknownKeysAreErrorsWithTheirLineAndASuggestion() throws {
        let file = try write("""
        version: 2
        retain: {pubic: true}
        rules: {unused-imports: off}
        strict: true
        """)

        XCTAssertEqual(try problems(loading: file), [
            "\(file.string):2:10: unknown key 'retain.pubic' (did you mean 'retain.public'?)",
            "\(file.string):3:9: unknown key 'rules.unused-imports' (did you mean 'rules.unused-import'?)",
            "\(file.string):4:1: unknown key 'strict' (did you mean 'report.strict'?)",
        ])
    }

    func testWrongTypeIsAnErrorWithItsLine() throws {
        let file = try write("version: 2\nreport:\n  strict: maybe\n")

        XCTAssertEqual(try problems(loading: file), ["\(file.string):3:11: 'report.strict' must be a boolean"])
    }

    func testInvalidEnumValueIsAnErrorWithItsLine() throws {
        let file = try write("version: 2\nreport: {format: jsno}\n")
        let formats = OutputFormat.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")

        XCTAssertEqual(try problems(loading: file), ["\(file.string):2:18: 'report.format': expected one of \(formats), got 'jsno'"])
    }

    func testWrongValueIsAnError() throws {
        for yaml in ["report: {strict: maybe}", "report: {format: jsno}", "rules: {unused-import: sometimes}", "retain: {objc: all}", "retain: {properties_of: [Codable, Sendable]}"] {
            let file = try write("version: 2\n" + yaml)

            XCTAssertThrowsError(try Configuration().load(from: file) { _ in }, yaml) { error in
                XCTAssertTrue(error is ConfigurationFileError, "\(error)")
                XCTAssertTrue(error.localizedDescription.hasPrefix("\(file.string):2:"), error.localizedDescription)
                XCTAssertFalse(error.localizedDescription.contains("\n"), error.localizedDescription)
            }
        }
    }

    func testEveryProblemIsReportedTogetherInLineOrder() throws {
        let file = try write("""
        version: 2
        report:
          format: jsno
          strict: maybe
          colour: auto
        retain:
          objc: all
        rules: {unused-import: sometimes, redundant-open: on, missing-final: off}
        """)

        let reported = try problems(loading: file)

        XCTAssertEqual(reported.map { $0.split(separator: ":").dropFirst().prefix(2).joined(separator: ":") }, ["3:11", "4:11", "5:3", "7:9", "8:24", "8:70"], reported.joined(separator: "\n"))
        XCTAssertTrue(reported[2].hasSuffix("unknown key 'report.colour' (did you mean 'report.color'?)"), reported[2])
        XCTAssertTrue(reported[5].hasSuffix("'rules.redundant-open' and 'rules.missing-final' must have the same value, they are not configurable separately yet"), reported[5])
    }

    func testValidEntriesNextToAProblemAreStillRead() throws {
        let file = try write("version: 2\nreport: {format: jsno, exit_codes: v2}\n")
        let configuration = Configuration()

        XCTAssertThrowsError(try configuration.load(from: file) { _ in })
        XCTAssertEqual(configuration.exitCodes, .v2)
    }

    func testAlwaysCheckedRuleCannotBeTurnedOff() throws {
        let file = try write("version: 2\nrules: {unused: off}\n")

        XCTAssertEqual(try problems(loading: file), ["\(file.string):2:17: 'rules.unused' cannot be turned off, the rule is always checked"])
    }

    func testRulesSharingAV1KeyMustAgree() throws {
        let file = try write("version: 2\nrules: {redundant-open: on, missing-final: off}\n")

        XCTAssertEqual(try problems(loading: file), ["\(file.string):2:44: 'rules.redundant-open' and 'rules.missing-final' must have the same value, they are not configurable separately yet"])
    }

    // MARK: - Version 1 files

    func testVersion1FileLoadsAsWithoutVersion() throws {
        var warnings: [String] = []
        let configuration = Configuration()
        try configuration.load(from: write("version: 1\nstrict: true\n")) { warnings.append($0) }

        XCTAssertEqual(warnings, [])
        XCTAssertTrue(configuration.strict)
    }

    func testV1FileStillWarnsOnV2Keys() throws {
        var warnings: [String] = []
        let file = try write("rules: {unused: on}\nstrict: true\n")
        let configuration = Configuration()
        try configuration.load(from: file) { warnings.append($0) }

        XCTAssertEqual(warnings, ["\(file.string): invalid key 'rules'"])
        XCTAssertTrue(configuration.strict)
    }

    func testV1FileOnlyWarnsOnTheMistakesThatAreErrorsInV2() throws {
        var warnings: [String] = []
        let file = try write("retain_pubic: true\nstrict: maybe\nformat: jsno\n")
        try Configuration().load(from: file) { warnings.append($0) }

        XCTAssertEqual(warnings.count, 3, warnings.joined(separator: "\n"))
        XCTAssertTrue(warnings.allSatisfy { $0.hasPrefix("\(file.string): ") }, warnings.joined(separator: "\n"))
    }

    func testUnsupportedVersionIsAnError() throws {
        for yaml in ["version: 3\n", "version: \"2\"\n", "version: true\n"] {
            let file = try write(yaml)

            XCTAssertThrowsError(try Configuration().load(from: file) { _ in }, yaml) { error in
                XCTAssertTrue(error.localizedDescription.hasPrefix("\(file.string): unsupported 'version'"), error.localizedDescription)
            }
        }
    }

    // MARK: - Extends

    func testExtendsASingleFile() throws {
        try write("version: 2\nretain: {public: true}\nreport: {format: json, strict: true}\n", named: "base.yml")
        let configuration = try loadV2("version: 2\nextends: base.yml\nreport: {format: sarif}\n")

        XCTAssertTrue(configuration.retainPublic)
        XCTAssertTrue(configuration.strict)
        XCTAssertEqual(configuration.outputFormat, .sarif)
    }

    func testExtendsAListWhereLaterFilesWin() throws {
        try write("version: 2\nreport: {format: json, verbose: true}\nrules: {missing-final: on}\n", named: "first.yml")
        try write("version: 2\nreport: {format: csv}\n", named: "second.yml")
        let configuration = try loadV2("version: 2\nextends: [first.yml, second.yml]\nrules: {redundant-open: on}\n")

        XCTAssertEqual(configuration.outputFormat, .csv)
        XCTAssertTrue(configuration.verbose)
        XCTAssertTrue(configuration.isEnabled(.missingFinal))
    }

    func testExtendsIsChainedWithPathsRelativeToEachFile() throws {
        try write("version: 2\nreport: {format: json, quiet: true}\nretain: {public: true}\n", named: "shared/base/root.yml")
        try write("version: 2\nextends: base/root.yml\nreport: {format: csv}\n", named: "shared/middle.yml")
        let configuration = try loadV2("version: 2\nextends: shared/middle.yml\nretain: {public: false}\n")

        XCTAssertEqual(configuration.outputFormat, .csv)
        XCTAssertTrue(configuration.quiet)
        XCTAssertFalse(configuration.retainPublic)
    }

    func testExtendsCycleIsAnError() throws {
        try write("version: 2\nextends: ../.outskirts.yml\n", named: "shared/base.yml")
        let file = try write("version: 2\nextends: shared/base.yml\n")
        let problems = try problems(loading: file)
        let root = FilePath(directory.path)

        XCTAssertEqual(problems, [
            "\(root.appending("shared/base.yml").string):2:10: 'extends' forms a cycle: \(root.appending(".outskirts.yml").string) -> \(root.appending("shared/base.yml").string) -> \(root.appending(".outskirts.yml").string)",
        ])
    }

    func testExtendingAMissingOrVersion1FileIsAnError() throws {
        try write("retain_public: true\n", named: "v1.yml")
        let file = try write("version: 2\nextends:\n  - missing.yml\n  - v1.yml\n")

        XCTAssertEqual(try problems(loading: file), [
            "\(file.string):3:5: 'extends' names 'missing.yml', which does not exist",
            "\(file.string):4:5: 'extends' names 'v1.yml', which is not a configuration file with 'version: 2'",
        ])
    }

    func testProblemsOfAnExtendedFileNameThatFile() throws {
        let base = try write("version: 2\nretain: {pubic: true}\n", named: "base.yml")
        let file = try write("version: 2\nextends: base.yml\nreport: {format: xml}\n")

        let problems = try problems(loading: file)

        XCTAssertEqual(problems.count, 2, "\(problems)")
        XCTAssertTrue(problems[0].hasPrefix("\(base.string):2:10: unknown key 'retain.pubic'"), problems[0])
        XCTAssertTrue(problems[1].hasPrefix("\(file.string):3:18: "), problems[1])
    }

    func testIndexDefaultsChoiceIsInherited() throws {
        try write("version: 2\nexclude: {index: [\"**/Gen/**\"], index_defaults: false}\n", named: "base.yml")

        XCTAssertEqual(try loadV2("version: 2\nextends: base.yml\nexclude: {index: [\"**/Other/**\"]}\n").indexExclude, ["**/Other/**"])
        XCTAssertEqual(
            Set(try loadV2("version: 2\nextends: base.yml\nexclude: {index_defaults: true}\n").indexExclude),
            Set(["**/Gen/**"] + Configuration().indexExclude)
        )
    }

    // MARK: - File-relative globs

    func testGlobsAreRelativeToTheDeclaringFile() throws {
        try write("""
        version: 2
        exclude: {index: ["Generated/**", "**/Pods/**"], localized_string_catalogs: [Other.xcstrings]}
        retain: {files: ["../Legacy/*.swift"]}
        """, named: "shared/base.yml")
        let configuration = try loadV2("""
        version: 2
        extends: shared/base.yml
        exclude: {report: ["Old/**:unused", {path: "Kit/**", kinds: [unused.function]}]}
        report: {include: ["./Sources/**", "/abs/**"]}
        """)
        let root = FilePath(directory.path)

        XCTAssertEqual(Set(configuration.indexExclude), Set([root.appending("shared/Generated/**").string, "**/Pods/**"] + Configuration().indexExclude))
        XCTAssertEqual(configuration.localizedStringCatalogExclude, [root.appending("shared/Other.xcstrings").string])
        XCTAssertEqual(configuration.retainFiles, [root.appending("Legacy/*.swift").string])
        XCTAssertEqual(configuration.reportExclude, [
            .pattern(root.appending("Old/**:unused").string),
            .scoped(path: root.appending("Kit/**").string, kinds: ["unused.function"]),
        ])
        XCTAssertEqual(configuration.reportInclude, [root.appending("Sources/**").string, "/abs/**"])

        configuration.buildFilenameMatchers()
        XCTAssertTrue(configuration.retainFilesMatchers.anyMatch(filename: root.appending("Legacy/Old.swift").string))
        XCTAssertFalse(configuration.retainFilesMatchers.anyMatch(filename: root.appending("shared/Legacy/Old.swift").string))
    }

    func testVersion1GlobsStayRelativeToTheCurrentDirectory() throws {
        let configuration = try loadV1("index_exclude: [\"Generated/**\"]\nretain_files: [\"Legacy/**\"]\n")

        XCTAssertEqual(configuration.retainFiles, ["Legacy/**"])
        XCTAssertTrue(configuration.indexExclude.contains("Generated/**"))
    }

    // MARK: - Overrides

    func testOverridesAreResolvedPerDeclaration() throws {
        let configuration = try loadV2("""
        version: 2
        overrides:
          - modules: ["Kit*"]
            retain: {public: true}
            rules: {redundant-public: off}
          - paths: ["Generated/**"]
            retain: {all: true}
          - modules: [KitTesting]
            retain: {public: false}
            rules: {redundant-public: on}
        """)
        let root = FilePath(directory.path)
        let source = root.appending("Sources/File.swift")

        let kit = configuration.settings(forModules: ["KitCore"], path: source)
        XCTAssertEqual(kit.publicRetentionKey, "overrides")
        XCTAssertFalse(kit.isEnabled(.redundantPublic))
        XCTAssertFalse(kit.retainsAll)

        let app = configuration.settings(forModules: ["App"], path: source)
        XCTAssertFalse(app.retainsPublic)
        XCTAssertTrue(app.isEnabled(.redundantPublic))

        let testing = configuration.settings(forModules: ["KitTesting"], path: source)
        XCTAssertFalse(testing.retainsPublic)
        XCTAssertTrue(testing.isEnabled(.redundantPublic))

        XCTAssertTrue(configuration.settings(forModules: ["App"], path: root.appending("Generated/Model.swift")).retainsAll)
        XCTAssertFalse(configuration.settings(forModules: ["App"], path: root.appending("Sources/Generated/Model.swift")).retainsAll)
        XCTAssertTrue(configuration.retainsPublicDeclarations)
    }

    func testOverridesOfExtendedFilesComeFirst() throws {
        try write("version: 2\noverrides:\n  - modules: [Kit]\n    retain: {public: true}\n", named: "base.yml")
        let configuration = try loadV2("version: 2\nextends: base.yml\noverrides:\n  - modules: [Kit]\n    retain: {public: false}\n")

        XCTAssertEqual(configuration.overrides.count, 2)
        XCTAssertFalse(configuration.settings(forModules: ["Kit"], path: "/Kit.swift").retainsPublic)
    }

    func testOverrideProblemsAreErrorsWithTheirLine() throws {
        let file = try write("""
        version: 2
        rules: {missing-final: off}
        overrides:
          - modules: [Kit]
            retain: {files: ["A/**"]}
          - retain: {public: true}
          - paths: ["B/**"]
            rules: {unused: off, missing-final: on}
          - modules: 3
        """)

        let problems = try problems(loading: file)

        XCTAssertEqual(problems.count, 6, "\(problems)")
        XCTAssertTrue(problems[0].hasPrefix("\(file.string):5:14: unknown key 'overrides[0].retain.files'"), problems[0])
        XCTAssertEqual(problems[1], "\(file.string):6:5: 'overrides[1]' must match 'modules' or 'paths'")
        XCTAssertTrue(problems[2].hasPrefix("\(file.string):8:21: 'overrides[2].rules.unused' cannot be set in an override"), problems[2])
        XCTAssertTrue(problems[3].hasPrefix("\(file.string):8:41: 'overrides[2].rules.missing-final' cannot turn on a rule that is off"), problems[3])
        // The entry is still checked without its invalid value.
        XCTAssertEqual(problems[4], "\(file.string):9:5: 'overrides[3]' must match 'modules' or 'paths'")
        XCTAssertTrue(problems[5].hasPrefix("\(file.string):9:14: "), problems[5])
    }

    func testVersion1FileHasNoOverrides() throws {
        XCTAssertTrue(try loadV1("retain_public: true\n").overrides.isEmpty)
    }

    // MARK: - Migration

    func testEveryV1KeyRoundTripsThroughMigrate() throws {
        let lines = Self.fullV1.split(separator: "\n").map(String.init) + [
            "disable_platform_conditional_retention: true",
            "disable_platform_conditional_retention: false",
            "retain_public: [Kit, Core]",
            "retain_objc_accessible: false",
            "retain_hashable_properties: true",
            "index_exclude: Generated/**",
            "report_exclude: [\"Legacy/**:unused.function\", {path: Kit/**, kinds: [unused.var]}]",
            "retain_files: [Sources/Legacy.swift, /abs/**, \"*.generated.swift\"]",
        ]

        for line in lines + [Self.fullV1, ""] {
            let file = try write(line + "\n")
            let migrated = try Configuration.migratedToV2(file: file)

            let (v2, v1) = try (migratedEffective(migrated), anchoredV1Effective(file))
            XCTAssertEqual(v2.keys.filter { v2[$0] != v1[$0] }.sorted().map { "\($0): \(v2[$0] ?? "") != \(v1[$0] ?? "")" }, [], line)
        }
    }

    func testMigratedConfigWithCLIIndexExcludeKeepsDefaults() throws {
        for yaml in ["index_exclude: [\"**/Gen/**\"]\n", "skip_build: true\n"] {
            let migrated = try Configuration.migratedToV2(file: write(yaml))
            XCTAssertFalse(migrated.contains("index_defaults"), migrated)
            XCTAssertEqual(migrated.contains("index:"), yaml.hasPrefix("index_exclude"), migrated)

            let v1 = try loadV1(yaml)
            let v2 = try loadV2(migrated)
            for configuration in [v1, v2] {
                configuration.apply(\.$indexExclude, ["**/CLI/**"])
            }
            XCTAssertEqual(Set(v2.indexExclude), Set(v1.indexExclude), yaml)
            XCTAssertTrue(Set(v2.indexExclude).isSuperset(of: Configuration().$indexExclude.defaultValue), yaml)
        }
    }

    func testMigrateWrapsAListKeyWrittenAsAScalar() throws {
        let keys = Configuration().settings.filter { [.stringList, .pathList].contains($0.kind) }.map(\.key)
        XCTAssertTrue(keys.contains("schemes") && keys.contains("retain_files"))

        for key in keys {
            let file = try write("\(key): \"**/Value\"\n")
            let migrated = try Configuration.migratedToV2(file: file)
            XCTAssertEqual(try migratedEffective(migrated), try anchoredV1Effective(file), key)
        }
    }

    func testMigrateAnchorsTheGlobsRelativeToTheFile() throws {
        let root = FilePath(directory.path)
        let file = try write("report_include: [Sources/**, \"**/Kit/**\"]\n", named: "config/outskirts.yml")

        let migrated = try Configuration.migratedToV2(file: file, projectRoot: root)

        XCTAssertTrue(migrated.contains("  include:\n  - ../Sources/**\n  - \"**/Kit/**\"\n"), migrated)
    }

    func testMigrateOutputIsStable() throws {
        let file = try write("""
        # yaml-language-server: $schema=https://raw.githubusercontent.com/tiny-earth-moon/outskirts/master/outskirts.schema.json
        # Scenario: an app with a framework.

        # The workspace.
        project: App.xcworkspace
        schemes:
          - App
          # The framework is built by the app scheme.
          - Kit  # second scheme
        retain_objc_accessible: true
        disable_unused_import_analysis: true  # noisy
        enable_open_final_analysis: true
        retain_codable_properties: true
        disable_update_check: true
        format: json
        index_exclude: ["**/Generated/**"]
        report_exclude:
          - path: "**/Legacy/**"
            kinds: [unused.function]
        variants: auto

        # Trailing notes.
        """)

        let migrated = try Configuration.migratedToV2(file: file)

        XCTAssertEqual(migrated, Self.migratedGolden)
        XCTAssertEqual(try Configuration.migratedToV2(file: write(String(contentsOf: file.url, encoding: .utf8), named: "again.yml")), migrated)
    }

    func testMigrateRejectsAFileThatWarnsOrIsAlreadyVersion2() throws {
        for yaml in ["retain_pubic: true\n", "strict: 1\n", "version: 2\n"] {
            XCTAssertThrowsError(try Configuration.migratedToV2(file: write(yaml)), yaml)
        }
    }

    func testSchemaValidatesTheMigratedExamples() throws {
        let validator = JSONSchemaValidator(schema: try Self.schema())
        let examples = ProjectRootPath.appending("examples")
        let files = try FileManager.default.contentsOfDirectory(atPath: examples.string).filter { $0.hasSuffix(".yml") }.sorted()
        XCTAssertFalse(files.isEmpty)

        for name in files {
            let source = try String(contentsOfFile: examples.appending(name).string, encoding: .utf8)
            let file = try write(source, named: name)
            let migrated = try Configuration.migratedToV2(file: file)

            // Through YAML rather than JSONSerialization: on Linux the latter turns booleans into `NSNumber` 0 and 1.
            let document = try XCTUnwrap(try Yams.load(yaml: migrated) as? [String: Any], name)
            XCTAssertEqual(validator.validate(document), [], name)
            XCTAssertEqual(try migratedEffective(migrated), try anchoredV1Effective(file), name)
            XCTAssertTrue(migrated.hasPrefix(Configuration.v2SchemaComment + "\n"), name)
        }
    }

    func testDocumentationListsEveryV1KeyAndItsV2Path() throws {
        let page = try Documentation.page("configuration")
        let table = Self.v1ToV2Table()
        let block = "<!-- v1-v2-keys:begin -->\n\(table)<!-- v1-v2-keys:end -->"

        XCTAssertTrue(page.contains(block), "docs/configuration.md is out of date, its table must be:\n\(table)")
    }

    // MARK: - Print

    func testPrintShowsTheEffectiveV2ConfigurationWithItsOverrides() throws {
        try write("version: 2\nreport: {format: json}\n", named: "base.yml")
        let configuration = Configuration()
        try configuration.load(from: write("""
        version: 2
        extends: base.yml
        rules: {missing-final: on, redundant-open: on}
        overrides:
          - modules: ["Kit*"]
            retain: {public: true}
            rules: {redundant-public: off}
        """)) { XCTFail("unexpected warning: \($0)") }

        XCTAssertEqual(try configuration.effectiveYAML(all: false), """
        # Read from \(directory.path)/base.yml, then \(directory.path)/.outskirts.yml
        version: 2
        rules:
          redundant-open: on
          missing-final: on
        report:
          format: json
        overrides:
        - modules: [Kit*]
          retain: {public: true}
          rules: {redundant-public: off}

        """)
    }

    func testPrintedV2ConfigurationLoadsBackIntoTheSameOne() throws {
        let configuration = try loadV2(Self.fullV2)

        for all in [false, true] {
            let printed = try configuration.effectiveYAML(all: all)
            XCTAssertEqual(effective(try loadV2(printed)), effective(configuration), printed)
        }
    }

    func testPrintOfAV1FileListsItsKeys() throws {
        let configuration = try loadV1("strict: true\nretain_public: true\n")

        XCTAssertEqual(try configuration.effectiveYAML(all: false), "retain_public: true\nstrict: true\n")

        let all = try XCTUnwrap(try Yams.load(yaml: configuration.effectiveYAML(all: true)) as? [String: Any])
        XCTAssertEqual(Set(all.keys), Set(configuration.settingKeys))
    }

    // MARK: - Schema

    func testSchemaDescribesEveryV2Path() throws {
        let schema = try Self.schema()
        let paths = ConfigurationKeyMapping.all.map(\.v2Path) + ConfigurationKeyMapping.v2OnlyPaths

        for path in paths {
            var node: [String: Any]? = schema
            for component in path.split(separator: ".") {
                node = (node?["properties"] as? [String: Any])?[String(component)] as? [String: Any]
            }
            XCTAssertNotNil(node, path)
        }
    }

    func testSchemaValidatesTheV2Files() throws {
        let validator = JSONSchemaValidator(schema: try Self.schema())

        let overrides = """
        version: 2
        extends: [base.yml, shared/other.yml]
        overrides:
          - modules: ["Kit*"]
            paths: ["Sources/**"]
            retain: {public: true, all: false}
            rules: {redundant-public: off, missing-final: on}
        """

        for yaml in [Self.fullV2, "version: 2\n", "version: 2\nrules: {unused: on}\nretain: {objc: off}\n", overrides] {
            // Through YAML rather than JSONSerialization: on Linux the latter turns booleans into `NSNumber` 0 and 1.
            let encoded = try YAMLEncoder().encode(try ConfigurationV2(yaml: yaml))
            var file = try XCTUnwrap(try Yams.load(yaml: encoded) as? [String: Any])
            file["version"] = 2
            XCTAssertEqual(validator.validate(file), [], yaml)
        }
    }

    func testSchemaRejectsUnknownKeys() throws {
        let validator = JSONSchemaValidator(schema: try Self.schema())

        XCTAssertFalse(validator.validate(["version": 2, "retain": ["pubic": true]]).isEmpty)
        XCTAssertFalse(validator.validate(["version": 2, "rules": ["unused-imports": "off"]]).isEmpty)
        XCTAssertFalse(validator.validate(["version": 1]).isEmpty)
        XCTAssertFalse(validator.validate(["version": 2, "overrides": [["modules": ["Kit"], "retain": ["files": ["A/**"]]]]]).isEmpty)
        XCTAssertFalse(validator.validate(["version": 2, "overrides": [["modules": ["Kit"], "rules": ["unused": "off"]]]]).isEmpty)
        XCTAssertFalse(validator.validate(["version": 2, "overrides": [["rules": ["redundant-public": "off"]]]]).isEmpty)
        XCTAssertFalse(validator.validate(["version": 2, "extends": [3]]).isEmpty)
    }

    // MARK: - Private

    private static func schema() throws -> [String: Any] {
        let data = try Data(contentsOf: ProjectRootPath.appending("schemas/config-v2.json").url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The value of every setting, `index_exclude` sorted as it is a set. With `resolvingAlias`, the platform
    /// conditional retention settings, which the `disable_platform_conditional_retention` alias overrides, are replaced
    /// by the retention they resolve to.
    private func effective(_ configuration: Configuration, resolvingAlias: Bool = false) -> [String: String] {
        Dictionary(uniqueKeysWithValues: configuration.settings.map { setting in
            let value = setting.wrappedValue
            if resolvingAlias, ["disable_platform_conditional_retention", "platform_conditional_retention"].contains(setting.key) {
                return (setting.key, "\(configuration.resolvedPlatformConditionalRetention)")
            }
            if setting.key == "index_exclude", let globs = value as? [String] {
                return (setting.key, "\(globs.sorted())")
            }
            return (setting.key, "\(value)")
        })
    }

    /// The Markdown table of the v1 keys, in the order of the schema, and their v2 paths.
    private static func v1ToV2Table() -> String {
        let notes = [
            "index_exclude": "the default globs are kept unless `exclude.index_defaults: false`",
            "retain_public": "a list of modules is `retain.public_modules`",
            "retain_objc_annotated": "`annotated`",
            "retain_objc_accessible": "`accessible`",
            "retain_codable_properties": "`Codable`",
            "retain_encodable_properties": "`Encodable`",
            "retain_equatable_properties": "`Equatable`",
            "retain_hashable_properties": "`Hashable`",
            "disable_platform_conditional_retention": "`true` is `off`",
            "disable_update_check": "`true` is `false`",
        ]
        var rows = ["| v1 key | v2 path | Note |", "|--------|---------|------|"]

        for key in Configuration().settingKeys {
            let paths = ConfigurationKeyMapping.all.filter { $0.v1Key == key }.map { "`\($0.v2Path)`" }
            let rule = RuleIdentifier.allCases.first { $0.v1Key == key }
            let note = notes[key] ?? (rule.map { $0.v1KeyTurnsRuleOff ? "`true` is `off`" : "`true` is `on`" } ?? "")
            rows.append("| `\(key)` | \(paths.joined(separator: ", ")) | \(note) |")
        }

        return rows.map { $0 + "\n" }.joined()
    }

    /// The effective configuration of a migrated file, loaded from a file next to the v1 one.
    private func migratedEffective(_ migrated: String) throws -> [String: String] {
        let configuration = Configuration()
        try configuration.load(from: write(migrated, named: "migrated.yml")) { XCTFail("unexpected warning: \($0)") }
        return effective(configuration, resolvingAlias: true)
    }

    /// The effective configuration of a v1 file, its relative globs anchored to the current directory, which they are
    /// relative to, as a v2 file anchors its globs to its directory.
    private func anchoredV1Effective(_ file: FilePath) throws -> [String: String] {
        let configuration = Configuration()
        try configuration.load(from: file) { XCTFail("unexpected warning: \($0)") }

        let anchor = { (glob: String) in Configuration.anchor(glob, to: .current) }
        configuration.indexExclude = configuration.indexExclude.map(anchor)
        configuration.reportInclude = configuration.reportInclude.map(anchor)
        configuration.retainFiles = configuration.retainFiles.map(anchor)
        configuration.localizedStringCatalogExclude = configuration.localizedStringCatalogExclude.map(anchor)
        configuration.reportExclude = configuration.reportExclude.map { entry in
            switch entry {
            case let .pattern(glob): .pattern(anchor(glob))
            case let .scoped(path, kinds): .scoped(path: anchor(path), kinds: kinds)
            case .malformed: entry
            }
        }
        return effective(configuration, resolvingAlias: true)
    }

    @discardableResult
    private func write(_ yaml: String, named name: String = ".outskirts.yml") throws -> FilePath {
        let file = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        return FilePath(file.path)
    }

    /// The problems that loading the file throws, each on its own line.
    private func problems(loading file: FilePath, file testFile: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        do {
            try Configuration().load(from: file) { XCTFail("unexpected warning: \($0)", file: testFile, line: line) }
        } catch let error as ConfigurationFileError {
            return error.problems
        }

        XCTFail("the file loads", file: testFile, line: line)
        return []
    }

    private func loadV1(_ yaml: String) throws -> Configuration {
        let configuration = Configuration()
        var warnings: [String] = []
        try configuration.load(from: write(yaml)) { warnings.append($0) }
        XCTAssertEqual(warnings, [], yaml)
        return configuration
    }

    private func loadV2(_ yaml: String) throws -> Configuration {
        let configuration = Configuration()
        try configuration.load(from: write(yaml)) { XCTFail("unexpected warning: \($0)") }
        return configuration
    }

    /// Every v1 key but the `disable_platform_conditional_retention` alias, with a value other than its default. The
    /// globs start with `**/`, which both formats read alike; other globs of a v2 file are relative to the file.
    private static let fullV1 = """
    project: App.xcodeproj
    schemes: [App]
    skip_schemes_validation: true
    xcode_list_arguments: [-quiet]
    json_package_manifest_path: package.json
    generic_project_config: generic.json
    build_arguments: [-c, release]
    skip_build: true
    clean_build: true
    index_store_path: [Index]
    strict_index: true
    quiet_index_store: true
    cache_max_age_days: 3
    cache_max_size_gb: 5
    variants: auto
    index_exclude: ["**/Generated/**"]
    report_exclude: ["**/Legacy/**", {path: "**/Kit/**", kinds: [unused.function]}]
    exclude_targets: [Tools]
    exclude_tests: true
    localized_string_catalog_exclude: ["**/Other.xcstrings"]
    format: json
    report_include: ["**/Sources/**"]
    relative_results: true
    relative_results_base: Sources
    changed_since: main
    changed_lines: true
    write_results: results.json
    skip_stdout_results: true
    strict: true
    exit_codes: v2
    verbose: true
    quiet: true
    color: never
    disable_update_check: true
    baseline: baseline.json
    write_baseline: new-baseline.json
    prune_baseline: true
    strict_baseline: true
    retain_public: true
    retain_public_modules: [Kit]
    no_retain_spi: [Internal]
    retain_files: ["**/Legacy/**"]
    retain_attributes: [IBSegueAction]
    retain_objc_annotated: true
    retain_objc_accessible: true
    retain_js_accessible: true
    retain_codable_properties: true
    retain_encodable_properties: true
    retain_equatable_properties: true
    retain_hashable_properties: true
    retain_assign_only_property_types: [Cancellable]
    external_codable_protocols: [Model]
    external_encodable_protocols: [Event]
    external_test_case_classes: [BaseTestCase]
    retain_unused_protocol_func_params: true
    retain_unused_parameters_without_default: true
    retain_swift_ui_previews: true
    retain_unused_imported_modules: [Shared]
    retain_synthesized_uses: true
    platform_conditional_retention: "off"
    localized_string_key_patterns: ["dynamic.*"]
    localized_string_key_literal_match: true
    retain_runtime_localized_keys: true
    disable_unused_import_analysis: true
    disable_unused_localized_string_analysis: true
    detect_unused_asset_catalog_colors: true
    detect_unused_asset_catalog_images: true
    retain_assign_only_properties: true
    enable_unassigned_optional_analysis: true
    disable_redundant_public_analysis: true
    enable_open_final_analysis: true
    enable_redundant_access_level_analysis: true
    enable_empty_extension_analysis: true
    superfluous_ignore_comments: false
    enable_redundant_public_members: true
    enable_unused_system_imports: true
    report_unused_type_parameters: true
    enable_unconstructed_enum_case_analysis: true
    detect_unused_metal_functions: true
    """

    /// The migration of the commented file of `testMigrateOutputIsStable`.
    private static let migratedGolden = """
    # yaml-language-server: $schema=https://raw.githubusercontent.com/tiny-earth-moon/outskirts/master/schemas/config-v2.json
    # Scenario: an app with a framework.
    version: 2
    project:
      # The workspace.
      path: App.xcworkspace
      # The framework is built by the app scheme.
      # second scheme
      schemes:
      - App
      - Kit
    variants: auto
    exclude:
      index:
      - "**/Generated/**"
      report:
      - path: "**/Legacy/**"
        kinds:
        - unused.function
    rules:
      unused-import: off  # noisy
      redundant-open: on
      missing-final: on
    retain:
      objc: accessible
      properties_of: [Codable]
    report:
      format: json
      update_check: false

    # Trailing notes.

    """

    /// `fullV1` written in the format 2.
    private static let fullV2 = """
    version: 2
    rules:
      unused-import: off
      unused-localized-string: off
      unused-asset-color: on
      unused-asset-image: on
      assign-only-property: off
      unassigned-optional: on
      redundant-public: off
      redundant-open: on
      missing-final: on
      redundant-access-level: on
      empty-extension: on
      superfluous-ignore: off
    retain:
      public: true
      public_modules: [Kit]
      public_excluded_spis: [Internal]
      files: ["**/Legacy/**"]
      attributes: [IBSegueAction]
      objc: [annotated, accessible]
      js_accessible: true
      properties_of: [Codable, Encodable, Equatable, Hashable]
      assign_only_property_types: [Cancellable]
      external_codable_protocols: [Model]
      external_encodable_protocols: [Event]
      external_test_case_classes: [BaseTestCase]
      unused_protocol_parameters: true
      unused_parameters_without_default: true
      swiftui_previews: true
      imported_modules: [Shared]
      synthesized_uses: true
      platform_conditional: off
      localized_string_keys: ["dynamic.*"]
      localized_string_literals: true
      runtime_localized_keys: true
    exclude:
      index: ["**/Generated/**"]
      report: ["**/Legacy/**", {path: "**/Kit/**", kinds: [unused.function]}]
      targets: [Tools]
      tests: true
      localized_string_catalogs: ["**/Other.xcstrings"]
    analysis:
      redundant_public_members: true
      unused_system_imports: true
      unused_type_parameters: true
      unconstructed_enum_cases: true
      metal_functions: true
    project:
      path: App.xcodeproj
      schemes: [App]
      skip_schemes_validation: true
      xcode_list_arguments: [-quiet]
      package_manifest: package.json
      generic_config: generic.json
    build:
      arguments: [-c, release]
      skip: true
      clean: true
      index_store_paths: [Index]
      strict_index: true
      quiet_index_store: true
      cache_max_age_days: 3
      cache_max_size_gb: 5
    report:
      format: json
      include: ["**/Sources/**"]
      relative: true
      relative_to: Sources
      changed_since: main
      changed_lines: true
      write: results.json
      skip_stdout: true
      strict: true
      exit_codes: v2
      verbose: true
      quiet: true
      color: never
      update_check: false
    baseline:
      path: baseline.json
      write: new-baseline.json
      prune: true
      strict: true
    variants: auto
    """
}
