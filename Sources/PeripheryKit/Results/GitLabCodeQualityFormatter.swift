import Configuration
import Foundation
import Logger
import SystemPackage

final class GitLabCodeQualityFormatter: OutputFormatter {
    static let requiresRelativePaths = true

    let configuration: Configuration
    let logger: Logger
    lazy var currentFilePath: FilePath = .current

    init(configuration: Configuration, logger: Logger) {
        self.logger = logger
        self.configuration = configuration
    }

    func format(_ results: [ScanResult], colored: Bool) throws -> String? {
        let jsonObject = results.map { result in
            var object = codeQualityIssue(result, colored: colored)
            object["severity"] = "info"
            return object
        }

        return try serializeJSON(jsonObject)
    }
}
