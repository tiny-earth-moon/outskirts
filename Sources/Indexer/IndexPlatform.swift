/// A platform a target is compiled for, read from the target triple of an index unit or from the SDK names of a
/// target. Device and simulator builds are the same platform; Mac Catalyst is a platform of its own.
public struct IndexPlatform: Hashable, Comparable, CustomStringConvertible, Sendable {
    public let name: String

    public static let iOS = IndexPlatform(name: "iOS")
    public static let macOS = IndexPlatform(name: "macOS")
    public static let macCatalyst = IndexPlatform(name: "Mac Catalyst")
    public static let tvOS = IndexPlatform(name: "tvOS")
    public static let watchOS = IndexPlatform(name: "watchOS")
    public static let visionOS = IndexPlatform(name: "visionOS")
    public static let driverKit = IndexPlatform(name: "DriverKit")
    public static let linux = IndexPlatform(name: "Linux")
    public static let windows = IndexPlatform(name: "Windows")

    /// The platform the tool runs on, which Swift Package Manager builds for unless told otherwise.
    public static var host: IndexPlatform {
        #if os(macOS)
            .macOS
        #elseif os(Windows)
            .windows
        #else
            .linux
        #endif
    }

    private init(name: String) {
        self.name = name
    }

    /// The platform of a target triple such as `arm64-apple-ios17.0-simulator`, `arm64-apple-ios17.0-macabi`,
    /// `x86_64-apple-macosx14.0` or `x86_64-unknown-linux-gnu`; `nil` for a triple it does not know.
    public init?(triple: String) {
        let components = triple.lowercased().split(separator: "-").map(String.init)
        guard components.count >= 3 else { return nil }

        let system = components[2]
        let environment = components.count > 3 ? components[3] : ""

        if system.hasPrefix("ios") {
            self = environment.hasPrefix("macabi") ? .macCatalyst : .iOS
        } else if system.hasPrefix("macos") || system.hasPrefix("darwin") {
            self = .macOS
        } else if system.hasPrefix("tvos") {
            self = .tvOS
        } else if system.hasPrefix("watchos") {
            self = .watchOS
        } else if system.hasPrefix("xros") || system.hasPrefix("visionos") {
            self = .visionOS
        } else if system.hasPrefix("driverkit") {
            self = .driverKit
        } else if system.hasPrefix("linux") {
            self = .linux
        } else if system.hasPrefix("windows") {
            self = .windows
        } else {
            return nil
        }
    }

    /// The platform of an SDK name of the `SDKROOT` or `SUPPORTED_PLATFORMS` build settings, such as `iphoneos`,
    /// `iphonesimulator` or `macosx`; `nil` for a name it does not know, such as `auto`.
    public init?(sdk: String) {
        switch sdk.lowercased() {
        case "iphoneos", "iphonesimulator": self = .iOS
        case "macosx": self = .macOS
        case "appletvos", "appletvsimulator": self = .tvOS
        case "watchos", "watchsimulator": self = .watchOS
        case "xros", "xrsimulator": self = .visionOS
        case "driverkit": self = .driverKit
        default: return nil
        }
    }

    public var description: String {
        name
    }

    public static func < (lhs: IndexPlatform, rhs: IndexPlatform) -> Bool {
        lhs.name < rhs.name
    }
}

/// What the index data must hold for a scanned target to be covered, with `strict_index_coverage`.
public struct CoverageTarget: Equatable, Sendable {
    /// The name of the module the target compiles, when the project tells it; units of other modules do not cover
    /// the target, unless no unit of the index has that module (the name is then likely wrong).
    public let moduleName: String?
    /// The platforms the target supports; empty when the project does not tell them, so that any platform covers it.
    public let platforms: Set<IndexPlatform>

    public init(moduleName: String?, platforms: Set<IndexPlatform>) {
        self.moduleName = moduleName
        self.platforms = platforms
    }
}
