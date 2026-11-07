import ArgumentParser
import Configuration
import Foundation
import Shared

/// The exit status of a failed command, under the contract selected by `--exit-codes` or `exit_codes`.
enum ExitStatus {
    /// The class of a failure that is not a `PeripheryError`, nil for the errors of the argument parser.
    private static func failureClass(of error: Error) -> FailureClass? {
        if Configuration.isMalformedFileError(error) || error is ConfigurationFileError {
            return .configuration
        }
        if error is ExitCode || error is CleanExit || error is ValidationError {
            return nil
        }

        return .project
    }

    /// The status to exit with: the argument parser's own for its errors (64 for usage errors), else the status of
    /// the failure class, which is `EXIT_FAILURE` for every class with `v1`.
    static func code(for error: Error, parserCode: Int32, mode: ExitCodes) -> Int32 {
        guard parserCode == EXIT_FAILURE else { return parserCode }

        if let error = error as? PeripheryError {
            return error.exitCode(for: mode)
        }
        guard let failureClass = failureClass(of: error) else { return parserCode }

        return failureClass.exitStatus(for: mode)
    }
}
