import Foundation
import Shared
import Yams

/// A build of a Swift package for one target triple, with an optional SDK and build configuration.
public struct BuildVariant: Hashable, Sendable {
    public let triple: String
    /// An SDK name resolved with `xcrun --sdk <name> --show-sdk-path` (e.g. `iphonesimulator`), or a path to the SDK.
    /// When nil, the SDK is derived from the triple on macOS, and left to SwiftPM elsewhere.
    public let sdk: String?
    /// The build configuration, `debug` or `release`; nil keeps the one of the build arguments.
    public let configuration: String?

    public init(triple: String, sdk: String? = nil, configuration: String? = nil) {
        self.triple = triple
        self.sdk = sdk
        self.configuration = configuration
    }

    static let keys = ["triple", "sdk", "configuration"]

    /// Parses the compact form `<triple>[,sdk=<sdk>][,configuration=<configuration>]`.
    init(spec: String) throws(SettingValueError) {
        let parts = spec.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let triple = parts.first, !triple.isEmpty, !triple.contains("=") else {
            throw .wrongType(expected: Self.expected, received: "the string \"\(spec)\"")
        }

        var values: [String: String] = [:]
        for part in parts.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, Self.keys.dropFirst().contains(pair[0]), !pair[1].isEmpty, values[pair[0]] == nil else {
                throw .wrongType(expected: Self.expected, received: "the string \"\(spec)\"")
            }

            values[pair[0]] = pair[1]
        }

        self.init(triple: triple, sdk: values["sdk"], configuration: values["configuration"])
    }

    /// Reads a list item of the configuration file: the compact form, or a mapping with `triple`, `sdk` and `configuration`.
    init(anyValue value: Any) throws(SettingValueError) {
        if let string = value as? String {
            try self.init(spec: string)
            return
        }

        guard let object = value as? [AnyHashable: Any] else {
            throw .wrongType(expected: Self.expected, received: "a list containing \(SettingValueError.describe(value))")
        }

        let keys = object.keys.compactMap { $0 as? String }
        guard keys.count == object.count, Set(keys).isSubset(of: Self.keys) else {
            throw .wrongType(expected: Self.expected, received: "a mapping with keys other than \(Self.keys.joined(separator: ", "))")
        }
        guard let triple = object["triple"] as? String, !triple.isEmpty else {
            throw .wrongType(expected: Self.expected, received: "a mapping without a string 'triple'")
        }

        let optional = { (key: String) throws(SettingValueError) -> String? in
            guard let value = object[key] else { return nil }
            guard let string = value as? String, !string.isEmpty else {
                throw .wrongType(expected: Self.expected, received: "'\(key)' as \(SettingValueError.describe(value))")
            }

            return string
        }

        try self.init(triple: triple, sdk: optional("sdk"), configuration: optional("configuration"))
    }

    /// The compact form, as accepted on the command line.
    public var spec: String {
        var parts = [triple]
        if let sdk {
            parts.append("sdk=\(sdk)")
        }
        if let configuration {
            parts.append("configuration=\(configuration)")
        }
        return parts.joined(separator: ",")
    }

    static let expected = "'default', 'auto', or a list of '<triple>[,sdk=<sdk>][,configuration=<configuration>]' or {triple, sdk, configuration}"
}

/// The builds a Swift package is scanned with.
public enum BuildVariants: Equatable, Sendable {
    /// The single build of the build arguments, as without the setting.
    case `default`
    /// One build per platform the package declares whose SDK is installed, or the host when it declares none.
    case auto
    /// The given builds.
    case explicit([BuildVariant])

    /// Reads the values given on the command line: `default`, `auto`, or one or more compact variants.
    public init(arguments: [String]) throws {
        do throws(SettingValueError) {
            try self.init(values: arguments)
        } catch let .wrongType(expected, received) {
            throw PeripheryError.usageError("'--variants' expects \(expected), got \(received ?? arguments.joined(separator: " "))")
        } catch let .invalidValue(received, _) {
            throw PeripheryError.usageError("'--variants' has an invalid value '\(received)'")
        }
    }

    init(values: [Any]) throws(SettingValueError) {
        if values.count == 1, let keyword = values.first as? String, let value = Self.keyword(keyword) {
            self = value
            return
        }
        guard !values.isEmpty else {
            throw .wrongType(expected: BuildVariant.expected, received: "an empty list")
        }

        if let keyword = values.compactMap({ $0 as? String }).first(where: { Self.keyword($0) != nil }) {
            throw .wrongType(expected: BuildVariant.expected, received: "'\(keyword)' among other variants")
        }

        var variants: [BuildVariant] = []
        for value in values {
            try variants.append(BuildVariant(anyValue: value))
        }
        self = .explicit(variants)
    }

    /// How the variants are named in messages.
    public var description: String {
        switch self {
        case .default: "default"
        case .auto: "auto"
        case let .explicit(variants): variants.map(\.spec).joined(separator: " ")
        }
    }

    private static func keyword(_ string: String) -> BuildVariants? {
        switch string {
        case "default": .default
        case "auto": .auto
        default: nil
        }
    }
}

extension SettingConverter {
    /// `default`, `auto`, a compact variant, or a list of variants.
    static let buildVariants: Conversion<BuildVariants> = { value throws(SettingValueError) in
        if let values = value as? [Any] {
            return try SettingConversion(BuildVariants(values: values))
        } else if value is String || value is [AnyHashable: Any] {
            return try SettingConversion(BuildVariants(values: [value]))
        }

        throw .wrongType(expected: BuildVariant.expected)
    }
}

extension BuildVariants: Yams.NodeRepresentable {
    public func represented() throws -> Node {
        switch self {
        case .default, .auto:
            return try description.represented()
        case let .explicit(variants):
            let nodes = variants.map { variant in
                var pairs: [(Node, Node)] = [(Node("triple"), Node(variant.triple))]
                if let sdk = variant.sdk {
                    pairs.append((Node("sdk"), Node(sdk)))
                }
                if let configuration = variant.configuration {
                    pairs.append((Node("configuration"), Node(configuration)))
                }
                return Node(pairs)
            }
            return Node(nodes)
        }
    }
}
