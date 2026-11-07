#if os(macOS)
    import Configuration
    import Foundation
    import Logger
    import Shared

    /// A build of the Xcode schemes resolved from the `variants` setting.
    struct XcodeBuildVariant: Equatable {
        /// How the variant is named in messages: its compact form, or `host`.
        let name: String
        /// The arguments added to the build arguments: destination, SDK and configuration. Empty for the host build,
        /// which keeps the DerivedData folder of the build arguments.
        let arguments: [String]
    }

    /// Resolves the `variants` setting into the `xcodebuild` builds to run.
    struct XcodeVariantResolver {
        let shell: Shell
        let logger: ContextualLogger
        /// Reports a variant that cannot be built.
        let warn: (String) -> Void
        let buildArguments: [String]
        var hostArchitecture = SPMVariantResolver.hostArchitectureName

        /// Build arguments that conflict with the destination, SDK and DerivedData folder each variant sets.
        static let conflictingOptions: Set = ["-destination", "-sdk", "-arch", "-derivedDataPath"]

        /// The SDK platforms in the order the `auto` builds run, each with the OS and environment of its triple.
        private static let platforms: [(sdks: Set<String>, os: String, suffix: String)] = [
            (["macosx"], "macosx", ""),
            (["iphoneos", "iphonesimulator"], "ios", "-simulator"),
            (["appletvos", "appletvsimulator"], "tvos", "-simulator"),
            (["watchos", "watchsimulator"], "watchos", "-simulator"),
            (["xros", "xrsimulator"], "xros", "-simulator"),
        ]

        /// - Parameter supportedPlatforms: the `SUPPORTED_PLATFORMS` of the schemes' targets, read for `auto` only.
        func resolve(_ variants: BuildVariants, supportedPlatforms: () throws -> [String]) throws -> [XcodeBuildVariant] {
            switch variants {
            case .default:
                return [XcodeBuildVariant(name: "host", arguments: [])]
            case .auto:
                try rejectConflictingBuildArguments(setsConfiguration: false)
                let declared = try platformVariants(for: supportedPlatforms())
                let resolved = try declared.compactMap(resolve)
                if resolved.isEmpty {
                    if !declared.isEmpty {
                        warn("No SDK of the platforms supported by the schemes is installed, building for the host only.")
                    }
                    return [XcodeBuildVariant(name: "host", arguments: [])]
                }
                return resolved
            case let .explicit(variants):
                try rejectConflictingBuildArguments(setsConfiguration: variants.contains { $0.configuration != nil })
                let resolved = try variants.compactMap(resolve)
                guard !resolved.isEmpty else {
                    throw PeripheryError.buildFailed(message: "None of the variants can be built: \(variants.map(\.spec).joined(separator: ", ")).")
                }

                return resolved
            }
        }

        /// The variant of each platform in `SUPPORTED_PLATFORMS`, a simulator for the Apple platforms other than macOS.
        func platformVariants(for supportedPlatforms: [String]) -> [BuildVariant] {
            let supported = Set(supportedPlatforms)
            for platform in supported where !Self.platforms.contains(where: { $0.sdks.contains(platform) }) {
                logger.debug("Variants: no build for the supported platform '\(platform)'")
            }
            return Self.platforms
                .filter { !$0.sdks.isDisjoint(with: supported) }
                .map { BuildVariant(triple: "\(hostArchitecture)-apple-\($0.os)\($0.suffix)") }
        }

        /// The generic `xcodebuild` destination of an Apple triple, nil for other triples.
        static func destination(forTriple triple: String) -> String? {
            let components = triple.split(separator: "-")
            guard components.count >= 3, components[1] == "apple" else { return nil }

            let os = components[2]
            let environment = components.count > 3 ? components[3] : ""
            let simulator = environment == "simulator" ? " Simulator" : ""

            if environment == "macabi" {
                return "generic/platform=macOS,variant=Mac Catalyst"
            }
            if os.hasPrefix("macos") {
                return "generic/platform=macOS"
            }
            if os.hasPrefix("ios") {
                return "generic/platform=iOS\(simulator)"
            }
            if os.hasPrefix("tvos") {
                return "generic/platform=tvOS\(simulator)"
            }
            if os.hasPrefix("watchos") {
                return "generic/platform=watchOS\(simulator)"
            }
            if os.hasPrefix("xros") || os.hasPrefix("visionos") {
                return "generic/platform=visionOS\(simulator)"
            }
            return nil
        }

        // MARK: - Private

        /// The build of a variant, nil when its SDK is not installed.
        private func resolve(_ variant: BuildVariant) throws -> XcodeBuildVariant? {
            guard let destination = Self.destination(forTriple: variant.triple) else {
                throw PeripheryError.usageError("The variant '\(variant.spec)' cannot be built with xcodebuild: its triple names no Apple platform.")
            }

            if let name = variant.sdk ?? SPMVariantResolver.sdkName(forTriple: variant.triple), !name.contains("/"),
               try SPMVariantResolver.installedSDKPath(named: name, shell: shell) == nil
            {
                warn("Skipping the variant '\(variant.spec)': the SDK '\(name)' is not installed. Names written in the #if clauses of its platform stay retained.")
                return nil
            }

            var arguments = ["-destination", destination]
            if let sdk = variant.sdk {
                arguments += ["-sdk", sdk]
            }
            if let configuration = variant.configuration {
                arguments += ["-configuration", configuration]
            }
            return XcodeBuildVariant(name: variant.spec, arguments: arguments)
        }

        private func rejectConflictingBuildArguments(setsConfiguration: Bool) throws {
            let conflicting = setsConfiguration ? Self.conflictingOptions.union(["-configuration"]) : Self.conflictingOptions
            if let option = buildArguments.first(where: { conflicting.contains($0) }) {
                throw PeripheryError.usageError("The build argument '\(option)' cannot be combined with '--variants', which sets the destination, SDK, configuration and DerivedData folder of each build.")
            }
        }
    }
#endif
