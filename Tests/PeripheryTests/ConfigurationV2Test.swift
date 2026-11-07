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
            ("index_exclude: [\"Gen/**\"]\nexclude_tests: true\n", "exclude: {index: [\"Gen/**\"], tests: true}"),
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

    func testVersion2FileWithOnlyTheVersionLoadsTheDefaults() throws {
        let configuration = try loadV2("version: 2\n")

        XCTAssertFalse(configuration.hasNonDefaultValues)
    }

    func testIndexDefaultsAreKeptUnlessTurnedOff() throws {
        let kept = try loadV2("version: 2\nexclude: {index: [\"Gen/**\"]}\n")
        let dropped = try loadV2("version: 2\nexclude: {index: [\"Gen/**\"], index_defaults: false}\n")

        XCTAssertEqual(Set(kept.indexExclude), Set(["Gen/**"] + Configuration().indexExclude))
        XCTAssertEqual(dropped.indexExclude, ["Gen/**"])

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

        for yaml in [Self.fullV2, "version: 2\n", "version: 2\nrules: {unused: on}\nretain: {objc: off}\n"] {
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
    }

    // MARK: - Private

    private static func schema() throws -> [String: Any] {
        let data = try Data(contentsOf: ProjectRootPath.appending("schemas/config-v2.json").url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The value of every setting, `index_exclude` sorted as it is a set.
    private func effective(_ configuration: Configuration) -> [String: String] {
        Dictionary(uniqueKeysWithValues: configuration.settings.map { setting in
            let value = setting.wrappedValue
            if setting.key == "index_exclude", let globs = value as? [String] {
                return (setting.key, "\(globs.sorted())")
            }
            return (setting.key, "\(value)")
        })
    }

    private func write(_ yaml: String) throws -> FilePath {
        let file = directory.appendingPathComponent(".outskirts.yml")
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

    /// Every v1 key but the `disable_platform_conditional_retention` alias, with a value other than its default.
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
    cache_max_age_days: 3
    cache_max_size_gb: 5
    variants: auto
    index_exclude: ["Generated/**"]
    report_exclude: ["Legacy/**", {path: "Kit/**", kinds: [unused.function]}]
    exclude_targets: [Tools]
    exclude_tests: true
    localized_string_catalog_exclude: [Other.xcstrings]
    format: json
    report_include: ["Sources/**"]
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
    retain_files: ["Legacy/**"]
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
      files: ["Legacy/**"]
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
      index: ["Generated/**"]
      report: ["Legacy/**", {path: "Kit/**", kinds: [unused.function]}]
      targets: [Tools]
      tests: true
      localized_string_catalogs: [Other.xcstrings]
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
      cache_max_age_days: 3
      cache_max_size_gb: 5
    report:
      format: json
      include: ["Sources/**"]
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
