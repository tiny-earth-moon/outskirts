import SourceGraph
import SwiftIfConfig
import SwiftSyntax

/// The platform part of the build configuration an index unit was compiled for, derived from its target triple.
///
/// Only `os()`, `arch()` and `targetEnvironment()` are answered, and only for names known to the compiler. Every
/// other query (custom flags, `canImport()`, `hasFeature()`, `swift()`, `compiler()`...) cannot be answered from a
/// triple and throws, which makes the evaluation of the enclosing `#if` fail.
///
/// `answeringCanImport` also answers `canImport()` for the system modules whose presence the platform settles, such
/// as `Dispatch` on Apple platforms or `UIKit` on macOS, and for the project's modules the build compiled.
public struct PlatformBuildConfiguration: BuildConfiguration, Hashable {
    struct UnsupportedQuery: Error {}

    private static let knownOperatingSystems: Set<String> = [
        "macOS", "OSX", "iOS", "tvOS", "watchOS", "visionOS", "Linux", "Windows", "Android", "FreeBSD", "OpenBSD",
        "WASI", "Haiku", "PS4", "Cygwin", "none",
    ]
    private static let knownArchitectures: Set<String> = [
        "arm", "arm64", "arm64_32", "i386", "x86_64", "powerpc", "powerpc64", "powerpc64le", "s390x", "wasm32",
        "riscv64",
    ]
    private static let knownEnvironments: Set<String> = ["simulator", "macCatalyst"]

    let operatingSystems: Set<String>
    let architecture: String
    let environment: String?
    /// The project's modules the build compiled, which it can import.
    private(set) var projectModules: Set<String> = []
    private(set) var answersCanImport = false
    /// The answer of `canImport()` for a module whose presence is not known, which throws when nil.
    private(set) var unknownModulesAreImportable: Bool?
    /// The answer for every custom condition (`DEBUG`, a flag), which throws when nil: the index store does not record
    /// the conditions a unit was compiled with.
    private(set) var customConditionsAreSet: Bool?

    /// The configuration, also answering `canImport()` for the system modules the platform settles and the project's
    /// modules the build compiled.
    var answeringCanImport: PlatformBuildConfiguration {
        var configuration = self
        configuration.answersCanImport = true
        return configuration
    }

    /// The configurations of the builds, or none when one of their triples is not understood, in which case every
    /// clause of a platform conditional is to be collected.
    /// The configuration answering `canImport()` with `importable` for the modules whose presence is not known: a
    /// condition that evaluates the same with both answers does not depend on them.
    func assumingUnknownModules(importable: Bool) -> PlatformBuildConfiguration {
        var configuration = self
        configuration.unknownModulesAreImportable = importable
        return configuration
    }

    /// The configuration answering every custom condition with `set`: a condition that evaluates the same with both
    /// answers does not depend on them.
    func assumingCustomConditions(set: Bool) -> PlatformBuildConfiguration {
        var configuration = self
        configuration.customConditionsAreSet = set
        return configuration
    }

    /// - Parameter modulesByVariant: the project's modules each build compiled, which `answeringCanImport` answers.
    public static func configurations(
        of variants: Set<IndexVariant>,
        modulesByVariant: [IndexVariant: Set<String>] = [:]
    ) -> [PlatformBuildConfiguration] {
        var configurations: Set<PlatformBuildConfiguration> = []

        for variant in variants {
            guard var configuration = PlatformBuildConfiguration(triple: variant.triple) else { return [] }

            configuration.projectModules = modulesByVariant[variant, default: []]
            configurations.insert(configuration)
        }

        return Array(configurations)
    }

    /// Returns `nil` when the triple describes a platform whose conditions are not known with certainty.
    init?(triple: String) {
        let components = triple.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 3 || components.count == 4 else { return nil }

        switch components[0] {
        case "arm64", "aarch64": architecture = "arm64"
        case "x86_64": architecture = "x86_64"
        default: return nil
        }

        let osName = String(components[2].prefix { $0.isLetter })
        let environmentName = components.count == 4 ? components[3] : nil
        let isApple = components[1] == "apple"

        switch (isApple, osName, environmentName) {
        case (true, "macosx", nil), (true, "macos", nil):
            operatingSystems = ["macOS", "OSX"]
            environment = nil
        case (true, "ios", "macabi"):
            operatingSystems = ["iOS"]
            environment = "macCatalyst"
        case (true, "ios", _), (true, "tvos", _), (true, "watchos", _), (true, "xros", _), (true, "visionos", _):
            guard environmentName == nil || environmentName == "simulator" else { return nil }

            operatingSystems = [Self.appleOperatingSystem(osName)]
            environment = environmentName
        case (false, "linux", "gnu"), (false, "linux", "musl"):
            operatingSystems = ["Linux"]
            environment = nil
        default:
            return nil
        }
    }

    public func isCustomConditionSet(name _: String) throws -> Bool {
        guard let customConditionsAreSet else { throw UnsupportedQuery() }

        return customConditionsAreSet
    }

    public func hasFeature(name _: String) throws -> Bool {
        throw UnsupportedQuery()
    }

    public func hasAttribute(name _: String) throws -> Bool {
        throw UnsupportedQuery()
    }

    public func canImport(importPath: [(TokenSyntax, String)], version: CanImportVersion) throws -> Bool {
        guard answersCanImport,
              importPath.count == 1,
              let module = importPath.first?.1,
              case .unversioned = version,
              let canImport = canImport(module: module) ?? unknownModulesAreImportable
        else { throw UnsupportedQuery() }

        return canImport
    }

    public func isActiveTargetOS(name: String) throws -> Bool {
        guard Self.knownOperatingSystems.contains(name) else { throw UnsupportedQuery() }

        return operatingSystems.contains(name)
    }

    public func isActiveTargetArchitecture(name: String) throws -> Bool {
        guard Self.knownArchitectures.contains(name) else { throw UnsupportedQuery() }

        return architecture == name
    }

    public func isActiveTargetEnvironment(name: String) throws -> Bool {
        guard Self.knownEnvironments.contains(name) else { throw UnsupportedQuery() }

        return environment == name
    }

    public func isActiveTargetRuntime(name _: String) throws -> Bool {
        throw UnsupportedQuery()
    }

    public func isActiveTargetPointerAuthentication(name _: String) throws -> Bool {
        throw UnsupportedQuery()
    }

    public func isActiveTargetObjectFormat(name _: String) throws -> Bool {
        throw UnsupportedQuery()
    }

    public var targetPointerBitWidth: Int {
        64
    }

    public var targetAtomicBitWidths: [Int] {
        []
    }

    public var endianness: Endianness {
        .little
    }

    /// Never queried: conditions other than `os()`, `arch()` and `targetEnvironment()` are not evaluated.
    public var languageVersion: VersionTuple {
        VersionTuple(0)
    }

    public var compilerVersion: VersionTuple {
        VersionTuple(0)
    }

    // MARK: - Private

    private static let appleModules: Set<String> = [
        "Darwin", "Dispatch", "Foundation", "ObjectiveC", "CoreFoundation", "Combine", "Security", "os",
        // The frameworks of every Apple SDK.
        "SwiftUI", "CoreData", "CoreGraphics", "CoreLocation", "AVFoundation", "CryptoKit", "Network", "OSLog",
        "StoreKit", "CloudKit", "GameKit", "UserNotifications",
    ]
    private static let linuxModules: Set<String> = ["Dispatch", "Foundation"]
    /// The modules of other platforms, absent from every platform of a known triple.
    private static let foreignModules: Set<String> = ["WinSDK", "ucrt", "CRT", "WASILibc", "wasi_pthread", "Bionic", "Android"]

    /// Whether the platform has the module, or nil when it is not known with certainty.
    private func canImport(module: String) -> Bool? {
        if projectModules.contains(module) {
            return true
        }
        if Self.foreignModules.contains(module) {
            return false
        }

        guard operatingSystems != ["Linux"] else {
            if Self.linuxModules.contains(module) {
                return true
            }
            return Self.appleModules.union(["UIKit", "AppKit"]).contains(module) ? false : nil
        }

        if Self.appleModules.contains(module) {
            return true
        }

        switch module {
        case "Glibc", "Musl":
            return false
        case "UIKit":
            // UIKit's availability on watchOS varies with the SDK.
            return operatingSystems.contains("watchOS") ? nil : !operatingSystems.contains("macOS")
        case "AppKit":
            // Mac Catalyst can import AppKit.
            return environment == "macCatalyst" ? nil : operatingSystems.contains("macOS")
        case "MetricKit":
            // The tvOS and watchOS SDKs do not have it.
            return operatingSystems.isDisjoint(with: ["tvOS", "watchOS"]) ? true : nil
        default:
            return nil
        }
    }

    private static func appleOperatingSystem(_ tripleName: String) -> String {
        switch tripleName {
        case "ios": "iOS"
        case "tvos": "tvOS"
        case "watchos": "watchOS"
        default: "visionOS"
        }
    }
}
