/// Where a key of the configuration format 1 lives in the format 2. Both formats load into the same settings, which
/// keep the v1 keys: a v2 file is read through this table, so the v1 keys are the only mapping layer.
struct ConfigurationKeyMapping: Sendable {
    let v1Key: String
    /// The dotted path of the option in a v2 file, e.g. `retain.public`.
    let v2Path: String
    /// The value a v2 file gives the v1 key, shaped like a v1 value; nil when the file leaves the path out. Absent for
    /// a v1 key that only exists as an alias of another one at the same path.
    let value: (@Sendable (ConfigurationV2) -> Any?)?

    init(_ v1Key: String, _ v2Path: String, _ value: (@Sendable (ConfigurationV2) -> Any?)?) {
        self.v1Key = v1Key
        self.v2Path = v2Path
        self.value = value
    }

    /// Every v1 key, some more than once when several v2 options drive it.
    static let all: [Self] = projectAndBuild + exclude + report + baseline + retain + rules + analysis

    /// The v2 paths that no v1 key drives.
    static let v2OnlyPaths = ["version", "extends", "overrides", "exclude.index_defaults"] + RuleIdentifier.allCases
        .filter { $0.v1Key == nil }
        .map { "rules.\($0.rawValue)" }

    /// The keys of an entry of `overrides`.
    static let overridePaths = ["modules", "paths", "retain.public", "retain.all"] + RuleIdentifier.allCases.map { "rules.\($0.rawValue)" }

    // MARK: - Private

    private static let projectAndBuild: [Self] = [
        .init("project", "project.path") { $0.project?.path },
        .init("schemes", "project.schemes") { $0.project?.schemes },
        .init("skip_schemes_validation", "project.skip_schemes_validation") { $0.project?.skipSchemesValidation },
        .init("xcode_list_arguments", "project.xcode_list_arguments") { $0.project?.xcodeListArguments },
        .init("json_package_manifest_path", "project.package_manifest") { $0.project?.packageManifest },
        .init("generic_project_config", "project.generic_config") { $0.project?.genericConfig },
        .init("build_arguments", "build.arguments") { $0.build?.arguments },
        .init("skip_build", "build.skip") { $0.build?.skip },
        .init("clean_build", "build.clean") { $0.build?.clean },
        .init("index_store_path", "build.index_store_paths") { $0.build?.indexStorePaths },
        .init("strict_index", "build.strict_index") { $0.build?.strictIndex },
        .init("quiet_index_store", "build.quiet_index_store") { $0.build?.quietIndexStore },
        .init("cache_max_age_days", "build.cache_max_age_days") { $0.build?.cacheMaxAgeDays },
        .init("cache_max_size_gb", "build.cache_max_size_gb") { $0.build?.cacheMaxSizeGB },
        .init("variants", "variants") { $0.variants?.native },
    ]

    private static let exclude: [Self] = [
        .init("index_exclude", "exclude.index") { $0.exclude?.index },
        .init("report_exclude", "exclude.report") { $0.exclude?.report?.native },
        .init("exclude_targets", "exclude.targets") { $0.exclude?.targets },
        .init("exclude_tests", "exclude.tests") { $0.exclude?.tests },
        .init("localized_string_catalog_exclude", "exclude.localized_string_catalogs") { $0.exclude?.localizedStringCatalogs },
    ]

    private static let report: [Self] = [
        .init("format", "report.format") { $0.report?.format?.rawValue },
        .init("report_include", "report.include") { $0.report?.include },
        .init("relative_results", "report.relative") { $0.report?.relative },
        .init("relative_results_base", "report.relative_to") { $0.report?.relativeTo },
        .init("changed_since", "report.changed_since") { $0.report?.changedSince },
        .init("changed_lines", "report.changed_lines") { $0.report?.changedLines },
        .init("write_results", "report.write") { $0.report?.write },
        .init("skip_stdout_results", "report.skip_stdout") { $0.report?.skipStdout },
        .init("strict", "report.strict") { $0.report?.strict },
        .init("exit_codes", "report.exit_codes") { $0.report?.exitCodes?.rawValue },
        .init("verbose", "report.verbose") { $0.report?.verbose },
        .init("quiet", "report.quiet") { $0.report?.quiet },
        .init("color", "report.color") { $0.report?.color?.rawValue },
        .init("disable_update_check", "report.update_check") { $0.report?.updateCheck.map { !$0 } },
    ]

    private static let baseline: [Self] = [
        .init("baseline", "baseline.path") { $0.baseline?.path },
        .init("write_baseline", "baseline.write") { $0.baseline?.write },
        .init("baseline_format", "baseline.format") { $0.baseline?.format?.rawValue },
        .init("prune_baseline", "baseline.prune") { $0.baseline?.prune },
        .init("strict_baseline", "baseline.strict") { $0.baseline?.strict },
    ]

    private static let retain: [Self] = [
        .init("retain_public", "retain.public") { $0.retain?.publicDeclarations },
        .init("retain_public_modules", "retain.public_modules") { $0.retain?.publicModules },
        .init("no_retain_spi", "retain.public_excluded_spis") { $0.retain?.publicExcludedSPIs },
        .init("retain_files", "retain.files") { $0.retain?.files },
        .init("retain_attributes", "retain.attributes") { $0.retain?.attributes },
        .init("retain_objc_annotated", "retain.objc") { $0.retain?.objc.map { $0.modes.contains(.annotated) } },
        .init("retain_objc_accessible", "retain.objc") { $0.retain?.objc.map { $0.modes.contains(.accessible) } },
        .init("retain_js_accessible", "retain.js_accessible") { $0.retain?.jsAccessible },
        .init("retain_codable_properties", "retain.properties_of") { $0.retain?.propertiesOf.map { $0.contains(.codable) } },
        .init("retain_encodable_properties", "retain.properties_of") { $0.retain?.propertiesOf.map { $0.contains(.encodable) } },
        .init("retain_equatable_properties", "retain.properties_of") { $0.retain?.propertiesOf.map { $0.contains(.equatable) } },
        .init("retain_hashable_properties", "retain.properties_of") { $0.retain?.propertiesOf.map { $0.contains(.hashable) } },
        .init("retain_assign_only_property_types", "retain.assign_only_property_types") { $0.retain?.assignOnlyPropertyTypes },
        .init("external_codable_protocols", "retain.external_codable_protocols") { $0.retain?.externalCodableProtocols },
        .init("external_encodable_protocols", "retain.external_encodable_protocols") { $0.retain?.externalEncodableProtocols },
        .init("external_test_case_classes", "retain.external_test_case_classes") { $0.retain?.externalTestCaseClasses },
        .init("retain_unused_protocol_func_params", "retain.unused_protocol_parameters") { $0.retain?.unusedProtocolParameters },
        .init("retain_unused_parameters_without_default", "retain.unused_parameters_without_default") { $0.retain?.unusedParametersWithoutDefault },
        .init("retain_swift_ui_previews", "retain.swiftui_previews") { $0.retain?.swiftUIPreviews },
        .init("retain_unused_imported_modules", "retain.imported_modules") { $0.retain?.importedModules },
        .init("retain_synthesized_uses", "retain.synthesized_uses") { $0.retain?.synthesizedUses },
        .init("platform_conditional_retention", "retain.platform_conditional") { $0.retain?.platformConditional?.rawValue },
        // `true` is `platform_conditional_retention: off`, which the v2 path sets directly.
        .init("disable_platform_conditional_retention", "retain.platform_conditional", nil),
        .init("localized_string_key_patterns", "retain.localized_string_keys") { $0.retain?.localizedStringKeys },
        .init("localized_string_key_literal_match", "retain.localized_string_literals") { $0.retain?.localizedStringLiterals },
        .init("retain_runtime_localized_keys", "retain.runtime_localized_keys") { $0.retain?.runtimeLocalizedKeys },
    ]

    private static let rules: [Self] = RuleIdentifier.allCases.compactMap { rule in
        guard let key = rule.v1Key else { return nil }

        return .init(key, "rules.\(rule.rawValue)") { $0.rules?[rule].map { rule.v1Value(enabled: $0.isOn) } }
    }

    private static let analysis: [Self] = [
        .init("enable_redundant_public_members", "analysis.redundant_public_members") { $0.analysis?.redundantPublicMembers },
        .init("enable_unused_system_imports", "analysis.unused_system_imports") { $0.analysis?.unusedSystemImports },
        .init("report_unused_type_parameters", "analysis.unused_type_parameters") { $0.analysis?.unusedTypeParameters },
        .init("enable_unconstructed_enum_case_analysis", "analysis.unconstructed_enum_cases") { $0.analysis?.unconstructedEnumCases },
        .init("detect_unused_metal_functions", "analysis.metal_functions") { $0.analysis?.metalFunctions },
    ]
}
