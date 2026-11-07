import Shared
import Yams

/// The options of the configuration file format 2, which a file opts into with `version: 2`, grouped by section. Every
/// value is optional, a value left out keeps the default. `ConfigurationKeyMapping` maps each one onto the setting it
/// shares with the format 1.
struct ConfigurationV2: Codable, Sendable {
    var rules: [RuleIdentifier: RuleState]?
    var retain: RetainSectionV2?
    var exclude: ExcludeSectionV2?
    var analysis: AnalysisSectionV2?
    var project: ProjectSectionV2?
    var build: BuildSectionV2?
    var report: ReportSectionV2?
    var baseline: BaselineSectionV2?
    var variants: YAMLValue?

    init(yaml: String) throws {
        self = try YAMLDecoder().decode(Self.self, from: yaml)
    }

    /// Whether a rule is checked: `on` or `off`, or a boolean.
    enum RuleState: Codable, Sendable {
        case on
        case off

        var isOn: Bool {
            self == .on
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()

            // YAML 1.1 reads an unquoted on/off as a boolean; the scalar is decoded as written.
            switch try container.decode(String.self).lowercased() {
            case "on", "true", "yes":
                self = .on
            case "off", "false", "no":
                self = .off
            case let value:
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "expected 'on' or 'off', got '\(value)'")
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(isOn ? "on" : "off")
        }
    }

    /// The Objective-C declarations retained: `off`, `annotated`, `accessible`, or a list of both.
    enum ObjcRetentionMode: String, CaseIterable, Codable, Sendable {
        case annotated
        case accessible

        init(from decoder: Decoder) throws {
            self = try Self.decodeRawValue(from: decoder)
        }
    }

    struct ObjcRetention: Codable, Sendable {
        var modes: Set<ObjcRetentionMode>

        init(from decoder: Decoder) throws {
            if var list = try probeShape({ try decoder.unkeyedContainer() }) {
                var modes = Set<ObjcRetentionMode>()
                while !list.isAtEnd {
                    modes.insert(try list.decode(ObjcRetentionMode.self))
                }
                self.modes = modes
                return
            }

            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if value == "off" {
                modes = []
            } else if let mode = ObjcRetentionMode(rawValue: value) {
                modes = [mode]
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "expected 'off', 'annotated', 'accessible' or a list of them, got '\(value)'")
            }
        }

        func encode(to encoder: Encoder) throws {
            if modes.isEmpty {
                var container = encoder.singleValueContainer()
                try container.encode("off")
            } else {
                var container = encoder.unkeyedContainer()
                try container.encode(contentsOf: modes.map(\.rawValue).sorted())
            }
        }
    }

    /// The protocols whose conforming types keep all their properties.
    enum PropertyRetentionProtocol: String, CaseIterable, Codable, Sendable {
        case codable = "Codable"
        case encodable = "Encodable"
        case equatable = "Equatable"
        case hashable = "Hashable"

        init(from decoder: Decoder) throws {
            self = try Self.decodeRawValue(from: decoder)
        }
    }
}

struct RetainSectionV2: Codable, Sendable {
    var publicDeclarations: Bool?
    var publicModules: [String]?
    var publicExcludedSPIs: [String]?
    var files: [String]?
    var attributes: [String]?
    var objc: ConfigurationV2.ObjcRetention?
    var jsAccessible: Bool?
    var propertiesOf: [ConfigurationV2.PropertyRetentionProtocol]?
    var assignOnlyPropertyTypes: [String]?
    var externalCodableProtocols: [String]?
    var externalEncodableProtocols: [String]?
    var externalTestCaseClasses: [String]?
    var unusedProtocolParameters: Bool?
    var unusedParametersWithoutDefault: Bool?
    var swiftUIPreviews: Bool?
    var importedModules: [String]?
    var synthesizedUses: Bool?
    var platformConditional: PlatformConditionalRetention?
    var localizedStringKeys: [String]?
    var localizedStringLiterals: Bool?
    var runtimeLocalizedKeys: Bool?

    enum CodingKeys: String, CodingKey {
        case publicDeclarations = "public"
        case publicModules = "public_modules"
        case publicExcludedSPIs = "public_excluded_spis"
        case files
        case attributes
        case objc
        case jsAccessible = "js_accessible"
        case propertiesOf = "properties_of"
        case assignOnlyPropertyTypes = "assign_only_property_types"
        case externalCodableProtocols = "external_codable_protocols"
        case externalEncodableProtocols = "external_encodable_protocols"
        case externalTestCaseClasses = "external_test_case_classes"
        case unusedProtocolParameters = "unused_protocol_parameters"
        case unusedParametersWithoutDefault = "unused_parameters_without_default"
        case swiftUIPreviews = "swiftui_previews"
        case importedModules = "imported_modules"
        case synthesizedUses = "synthesized_uses"
        case platformConditional = "platform_conditional"
        case localizedStringKeys = "localized_string_keys"
        case localizedStringLiterals = "localized_string_literals"
        case runtimeLocalizedKeys = "runtime_localized_keys"
    }
}

struct ExcludeSectionV2: Codable, Sendable {
    var index: [String]?
    /// Whether the default `index` globs are kept next to the given ones, true when left out as in the format 1.
    var indexDefaults: Bool?
    var report: YAMLValue?
    var targets: [String]?
    var tests: Bool?
    var localizedStringCatalogs: [String]?

    enum CodingKeys: String, CodingKey {
        case index
        case indexDefaults = "index_defaults"
        case report
        case targets
        case tests
        case localizedStringCatalogs = "localized_string_catalogs"
    }
}

/// Options of the rules that take more than on or off.
struct AnalysisSectionV2: Codable, Sendable {
    var redundantPublicMembers: Bool?
    var unusedSystemImports: Bool?
    var unusedTypeParameters: Bool?
    var unconstructedEnumCases: Bool?
    var metalFunctions: Bool?

    enum CodingKeys: String, CodingKey {
        case redundantPublicMembers = "redundant_public_members"
        case unusedSystemImports = "unused_system_imports"
        case unusedTypeParameters = "unused_type_parameters"
        case unconstructedEnumCases = "unconstructed_enum_cases"
        case metalFunctions = "metal_functions"
    }
}

struct ProjectSectionV2: Codable, Sendable {
    var path: String?
    var schemes: [String]?
    var skipSchemesValidation: Bool?
    var xcodeListArguments: [String]?
    var packageManifest: String?
    var genericConfig: String?

    enum CodingKeys: String, CodingKey {
        case path
        case schemes
        case skipSchemesValidation = "skip_schemes_validation"
        case xcodeListArguments = "xcode_list_arguments"
        case packageManifest = "package_manifest"
        case genericConfig = "generic_config"
    }
}

struct BuildSectionV2: Codable, Sendable {
    var arguments: [String]?
    var skip: Bool?
    var clean: Bool?
    var indexStorePaths: [String]?
    var strictIndex: Bool?
    var cacheMaxAgeDays: Int?
    var cacheMaxSizeGB: Int?

    enum CodingKeys: String, CodingKey {
        case arguments
        case skip
        case clean
        case indexStorePaths = "index_store_paths"
        case strictIndex = "strict_index"
        case cacheMaxAgeDays = "cache_max_age_days"
        case cacheMaxSizeGB = "cache_max_size_gb"
    }
}

struct ReportSectionV2: Codable, Sendable {
    var format: OutputFormat?
    var include: [String]?
    var relative: Bool?
    var relativeTo: String?
    var changedSince: String?
    var changedLines: Bool?
    var write: String?
    var skipStdout: Bool?
    var strict: Bool?
    var exitCodes: ExitCodes?
    var verbose: Bool?
    var quiet: Bool?
    var color: ColorOption?
    var updateCheck: Bool?

    enum CodingKeys: String, CodingKey {
        case format
        case include
        case relative
        case relativeTo = "relative_to"
        case changedSince = "changed_since"
        case changedLines = "changed_lines"
        case write
        case skipStdout = "skip_stdout"
        case strict
        case exitCodes = "exit_codes"
        case verbose
        case quiet
        case color
        case updateCheck = "update_check"
    }
}

struct BaselineSectionV2: Codable, Sendable {
    var path: String?
    var write: String?
    var prune: Bool?
    var strict: Bool?
}

/// A YAML value kept as written, for the options whose value takes several shapes (`variants`, `exclude.report`); the
/// setting reads it like a value of the format 1.
enum YAMLValue: Codable, Sendable {
    case scalar(String)
    case list([YAMLValue])
    case mapping([String: YAMLValue])

    /// The value as `Yams.load` returns it, which the settings read.
    var native: Any {
        switch self {
        case let .scalar(value):
            value
        case let .list(values):
            values.map(\.native)
        case let .mapping(values):
            values.mapValues(\.native)
        }
    }

    init(from decoder: Decoder) throws {
        if let mapping = try probeShape({ try decoder.container(keyedBy: AnyCodingKey.self) }) {
            self = try .mapping(Dictionary(uniqueKeysWithValues: mapping.allKeys.map { key in
                (key.stringValue, try mapping.decode(YAMLValue.self, forKey: key))
            }))
        } else if var list = try probeShape({ try decoder.unkeyedContainer() }) {
            var values: [YAMLValue] = []
            while !list.isAtEnd {
                values.append(try list.decode(YAMLValue.self))
            }
            self = .list(values)
        } else {
            self = try .scalar(decoder.singleValueContainer().decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .scalar(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .list(values):
            var container = encoder.unkeyedContainer()
            try container.encode(contentsOf: values)
        case let .mapping(values):
            var container = encoder.container(keyedBy: AnyCodingKey.self)
            for (key, value) in values.sorted(by: { $0.key < $1.key }) {
                try container.encode(value, forKey: AnyCodingKey(stringValue: key))
            }
        }
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue _: Int) {
            nil
        }
    }
}

/// The container that `body` opens, nil when the value has another shape (a scalar for a list, ...).
private func probeShape<Container>(_ body: () throws -> Container) throws -> Container? {
    do {
        return try body()
    } catch DecodingError.typeMismatch {
        return nil
    }
}

extension OutputFormat: Codable {
    public init(from decoder: Decoder) throws {
        self = try Self.decodeRawValue(from: decoder)
    }
}

extension ColorOption: Codable {
    public init(from decoder: Decoder) throws {
        self = try Self.decodeRawValue(from: decoder)
    }
}

extension PlatformConditionalRetention: Codable {
    public init(from decoder: Decoder) throws {
        self = try Self.decodeRawValue(from: decoder)
    }
}
