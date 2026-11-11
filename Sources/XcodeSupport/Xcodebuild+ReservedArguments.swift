import Foundation
import Shared

extension Xcodebuild {
    /// Options that choose where xcodebuild writes its products. outskirts builds into its own cache folder and reads the
    /// index store from there, and xcodebuild keeps the last occurrence of an option, so a configuration must not set them.
    /// Matched ignoring case, leading dashes and any `=value`, which also covers the `-IDE…=value` user defaults.
    static let reservedOptions = Set([
        "derivedDataPath",
        "archivePath",
        "exportPath",
        "resultBundlePath",
        "resultStreamPath",
        "testProductsPath",
        "clonedSourcePackagesDirPath",
        "packageCachePath",
        "localizationPath",
        "IDECustomDerivedDataLocation",
        "IDECustomBuildProductsPath",
        "IDECustomIntermediatesPath",
        "IDECustomBuildLocationType",
        "IDEBuildLocationStyle",
    ].map { $0.lowercased() })

    /// Build settings, given as `KEY=value`, that move the build or index directories.
    static let reservedBuildSettings: Set<String> = [
        "SYMROOT",
        "OBJROOT",
        "DSTROOT",
        "BUILD_DIR",
        "BUILD_ROOT",
        "CONFIGURATION_BUILD_DIR",
        "CONFIGURATION_TEMP_DIR",
        "TARGET_BUILD_DIR",
        "TARGET_TEMP_DIR",
        "PROJECT_TEMP_DIR",
        "PROJECT_TEMP_ROOT",
        "SHARED_PRECOMPS_DIR",
        "MODULE_CACHE_DIR",
        "INDEX_DATA_STORE_DIR",
    ]

    /// Throws a usage error naming the first argument of `setting` that would move the build out of outskirts' cache.
    static func validateUserArguments(_ arguments: [String], setting: String) throws {
        guard let argument = arguments.first(where: isReserved) else { return }

        throw PeripheryError.usageError(
            "'\(setting)' cannot contain '\(argument)': outskirts builds into its own cache folder and reads the index store from there. " +
                "To build elsewhere, build the project yourself, then scan with '--skip-build --index-store-path <path>'."
        )
    }

    static func isReserved(_ argument: String) -> Bool {
        if argument.hasPrefix("-") {
            let option = argument.drop { $0 == "-" }.prefix { $0 != "=" }
            return reservedOptions.contains(option.lowercased())
        }

        guard argument.contains("=") else { return false }

        // `KEY=value`, `KEY[sdk=iphoneos*]=value` or `KEY+=value`.
        let key = argument.prefix { $0 != "=" && $0 != "[" }.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: ["+"])
        return reservedBuildSettings.contains(key.uppercased())
    }
}
