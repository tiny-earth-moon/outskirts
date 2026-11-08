import Configuration
import Foundation
import Logger
import SystemPackage

class GitLabCodeQualityFormatter: OutputFormatter {
    static let requiresRelativePaths = true

    /// Whether each issue holds the output v2 id and rule of its result, the id also being its fingerprint.
    class var includesOutputV2Identity: Bool {
        false
    }

    let configuration: Configuration
    let logger: Logger
    lazy var currentFilePath: FilePath = .current

    required init(configuration: Configuration, logger: Logger) {
        self.logger = logger
        self.configuration = configuration
    }

    func format(_ results: [ScanResult], colored: Bool) throws -> String? {
        var jsonObject: [Any] = []

        for result in results {
            let violationFileLocation = declarationLocation(from: result.declaration)

            let description = describe(result, colored: colored)
                .map(\.1)
                .joined(separator: ", ")

            let checkName = describe(result.annotation)

            let identity = Self.includesOutputV2Identity ? (id: OutputV2Id.id(of: result), rule: result.rule) : nil
            let fingerprint = identity?.id ?? usrFingerprint(of: result)

            let begin = violationFileLocation.line
            let lines: [AnyHashable: Any] = [
                "begin": begin,
            ]

            let path = outputPath(violationFileLocation)
                .url
                .relativePath

            let location: [AnyHashable: Any] = [
                "path": path,
                "lines": lines,
            ]

            var object: [AnyHashable: Any] = [
                "description": description,
                "check_name": checkName,
                "fingerprint": fingerprint,
                "location": location,
                "severity": "info",
            ]

            if let identity {
                object["id"] = identity.id
                object["rule"] = identity.rule.rawValue
            }

            jsonObject.append(object)
        }

        return try serializeJSON(jsonObject)
    }
}

/// `gitlab-codequality-v2`: the `gitlab-codequality` format, each issue with the output v2 `id` and `rule` of its result, and the id as
/// its fingerprint.
final class GitLabCodeQualityV2Formatter: GitLabCodeQualityFormatter {
    override static var includesOutputV2Identity: Bool {
        true
    }
}
