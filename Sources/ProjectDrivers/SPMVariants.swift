import Configuration
import Extensions
import Foundation
import Logger
import Shared
import SystemPackage

/// A build of the package resolved from the `variants` setting.
struct SPMBuildVariant: Equatable {
    /// How the variant is named in messages: its compact form, or `host`.
    let name: String
    /// The arguments added to the build arguments: triple, SDK path, configuration and scratch path. Empty for the
    /// host build, which keeps the scratch path of the build arguments.
    let arguments: [String]
    /// The scratch path in the outskirts cache, nil for the host build.
    let scratchPath: FilePath?
}

/// Resolves the `variants` setting into the builds to run.
struct SPMVariantResolver {
    let shell: Shell
    let logger: ContextualLogger
    /// Reports a variant that cannot be built.
    let warn: (String) -> Void
    /// The project path, part of the cache key of each scratch path.
    let projectPath: FilePath
    let buildArguments: [String]
    var isMacOS = SPMVariantResolver.hostIsMacOS
    var hostArchitecture = SPMVariantResolver.hostArchitectureName
    /// The directory holding the scratch paths, the outskirts cache when nil.
    var cacheDirectory: FilePath?

    /// Build arguments that conflict with the triple, SDK and scratch path each variant sets.
    static let conflictingOptions: Set = ["--triple", "--sdk", "--arch", "--scratch-path", "--build-path"]

    func resolve(_ variants: BuildVariants, platforms: [PackageDescription.Platform]?) throws -> [SPMBuildVariant] {
        switch variants {
        case .default:
            return [SPMBuildVariant(name: "host", arguments: [], scratchPath: nil)]
        case .auto:
            try rejectConflictingBuildArguments()
            let declared = isMacOS ? platformVariants(for: platforms ?? []) : []
            let resolved = try declared.compactMap(resolve)
            if resolved.isEmpty {
                if !declared.isEmpty {
                    warn("No SDK of the platforms declared by the package is installed, building for the host only.")
                }
                return [SPMBuildVariant(name: "host", arguments: [], scratchPath: nil)]
            }
            return resolved
        case let .explicit(variants):
            try rejectConflictingBuildArguments()
            let resolved = try variants.compactMap(resolve)
            guard !resolved.isEmpty else {
                throw PeripheryError.usageError("None of the variants can be built: \(variants.map(\.spec).joined(separator: ", ")).")
            }

            return resolved
        }
    }

    /// The variant of each platform the package declares, a simulator for the Apple platforms other than macOS.
    func platformVariants(for platforms: [PackageDescription.Platform]) -> [BuildVariant] {
        platforms.compactMap { platform in
            let os: String
            var suffix = "-simulator"
            switch platform.name.lowercased() {
            case "macos":
                os = "macosx"
                suffix = ""
            case "ios": os = "ios"
            case "tvos": os = "tvos"
            case "watchos": os = "watchos"
            case "visionos": os = "xros"
            default:
                logger.debug("Variants: no build for the declared platform '\(platform.name)'")
                return nil
            }
            return BuildVariant(triple: "\(hostArchitecture)-apple-\(os)\(platform.version)\(suffix)")
        }
    }

    /// The SDK name of an Apple triple, nil for other triples.
    static func sdkName(forTriple triple: String) -> String? {
        let components = triple.split(separator: "-")
        guard components.count >= 3, components[1] == "apple" else { return nil }

        let os = components[2]
        let environment = components.count > 3 ? components[3] : ""
        let isSimulator = environment == "simulator"

        if os.hasPrefix("macos") || environment == "macabi" {
            return "macosx"
        }
        if os.hasPrefix("ios") {
            return isSimulator ? "iphonesimulator" : "iphoneos"
        }
        if os.hasPrefix("tvos") {
            return isSimulator ? "appletvsimulator" : "appletvos"
        }
        if os.hasPrefix("watchos") {
            return isSimulator ? "watchsimulator" : "watchos"
        }
        if os.hasPrefix("xros") || os.hasPrefix("visionos") {
            return isSimulator ? "xrsimulator" : "xros"
        }
        return nil
    }

    // MARK: - Private

    /// The build of a variant, nil when its SDK is not installed.
    private func resolve(_ variant: BuildVariant) throws -> SPMBuildVariant? {
        var arguments = ["--triple", variant.triple]

        if let sdk = try sdkPath(of: variant) {
            arguments += ["--sdk", sdk]
        } else if variant.sdk != nil || (isMacOS && Self.sdkName(forTriple: variant.triple) != nil) {
            return nil
        }

        if let configuration = variant.configuration {
            arguments += ["-c", configuration]
        }

        let scratchPath = try scratchPath(for: arguments)
        arguments += ["--scratch-path", scratchPath.string]
        return SPMBuildVariant(name: variant.spec, arguments: arguments, scratchPath: scratchPath)
    }

    /// The SDK path to pass, nil when there is none: a path is taken as is, a name is resolved with `xcrun` on macOS.
    /// A missing SDK is reported with a warning.
    private func sdkPath(of variant: BuildVariant) throws -> String? {
        if let sdk = variant.sdk, sdk.contains("/") {
            return sdk
        }
        guard isMacOS else { return variant.sdk }
        guard let name = variant.sdk ?? Self.sdkName(forTriple: variant.triple) else { return nil }

        do {
            let path = try shell.exec(["xcrun", "--sdk", name, "--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                return path
            }
        } catch PeripheryError.shellCommandFailed {
            // Reported below.
        }

        warn("Skipping the variant '\(variant.spec)': the SDK '\(name)' is not installed. Names written in the #if clauses of its platform stay retained.")
        return nil
    }

    /// A scratch path in the outskirts cache, keyed by the project, the variant and the build arguments.
    private func scratchPath(for variantArguments: [String]) throws -> FilePath {
        let directory = try cacheDirectory ?? Constants.cachePath()
        let key = (variantArguments + buildArguments).joined(separator: "\n")
        return directory.appending("\(CacheManager.packageBuildPrefix)\(projectPath.lexicallyNormalized().string.djb2Hex)-\(key.djb2Hex)")
    }

    private func rejectConflictingBuildArguments() throws {
        let given = SPM.Package.locationArguments(from: buildArguments).compactMap { argument -> String? in
            let option = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            return Self.conflictingOptions.contains(option) ? option : nil
        }
        if let option = given.first {
            throw PeripheryError.usageError("The build argument '\(option)' cannot be combined with '--variants', which sets the triple, SDK and scratch path of each build.")
        }
    }

    private static var hostIsMacOS: Bool {
        #if os(macOS)
            true
        #else
            false
        #endif
    }

    private static var hostArchitectureName: String {
        #if arch(arm64)
            "arm64"
        #else
            "x86_64"
        #endif
    }
}
