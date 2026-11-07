import Foundation
import Synchronization

/// The exit status contract: `v1` keeps the historical statuses, `v2` tells findings from failures.
public enum ExitCodes: String, CaseIterable, Codable, Equatable, Sendable {
    case v1
    case v2

    public static let `default` = ExitCodes.v1

    /// Findings with `--strict` or `--strict-baseline`.
    public static let findingsStatus: Int32 = 1
    /// With `v2`: the configuration, a setting or an option is invalid.
    public static let configurationErrorStatus: Int32 = 2
    /// With `v2`: the project, its build or its index store could not be used.
    public static let projectErrorStatus: Int32 = 3

    /// The contract in effect for the process: the `--exit-codes` option as soon as it is parsed, then the resolved
    /// configuration once the configuration file is loaded.
    public static var selected: ExitCodes {
        get { selection.withLock { $0 } }
        set { selection.withLock { $0 = newValue } }
    }

    private static let selection = Mutex<ExitCodes>(.default)

    public init(from decoder: Decoder) throws {
        self = try Self.decodeRawValue(from: decoder)
    }
}

/// The class of a failure, which gives its exit status under each contract.
public enum FailureClass: Equatable, Sendable {
    /// Unused code reported with `--strict`, or stale baseline entries with `--strict-baseline`.
    case findings
    /// A malformed configuration file, an invalid setting value, a rejected generic project config, options that
    /// cannot be combined.
    case configuration
    /// A project, build or index store failure, and every other failure that stops the scan.
    case project

    public func exitStatus(for mode: ExitCodes) -> Int32 {
        switch mode {
        case .v1:
            EXIT_FAILURE
        case .v2:
            switch self {
            case .findings: ExitCodes.findingsStatus
            case .configuration: ExitCodes.configurationErrorStatus
            case .project: ExitCodes.projectErrorStatus
            }
        }
    }
}
