import Configuration
import Foundation
import Logger
import SystemPackage

class CodeClimateFormatter: OutputFormatter {
    static let requiresRelativePaths = true

    /// Whether each issue holds the output v2 id and rule of its result, the id also being its fingerprint.
    class var includesOutputV2Identity: Bool { false }

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
            let location = declarationLocation(from: result.declaration)

            let lines: [AnyHashable: Any] = [
                "begin": location.line,
            ]

            let locationDict: [AnyHashable: Any] = [
                "path": outputPath(location).url.relativePath,
                "lines": lines,
            ]

            let description = describe(result, colored: colored)
                .map(\.1)
                .joined(separator: ", ")
            let identity = Self.includesOutputV2Identity ? (id: OutputV2Id.id(of: result), rule: result.rule) : nil
            let fingerprint = identity?.id ?? usrFingerprint(of: result)

            var object: [AnyHashable: Any] = [
                "type": "issue",
                "check_name": describe(result.annotation),
                "categories": ["Bug Risk"],
                "description": description,
                "fingerprint": fingerprint,
                "severity": "major",
                "location": locationDict,
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

/// `codeclimate-v2`: the `codeclimate` format, each issue with the output v2 `id` and `rule` of its result, and the id as
/// its fingerprint.
final class CodeClimateV2Formatter: CodeClimateFormatter {
    override class var includesOutputV2Identity: Bool { true }
}
