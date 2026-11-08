import Configuration
import Foundation
import Logger
import SourceGraph
import SystemPackage

class CheckstyleFormatter: OutputFormatter {
    /// A message of the report: where, what, and the output v2 id and rule of its result when they are included.
    private struct Part {
        let location: Location
        let message: String
        let identity: (id: String, rule: RuleIdentifier)?
    }

    /// Whether each error holds the output v2 id of its result and its rule as `source`.
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

    func format(_ results: [ScanResult], colored: Bool) -> String? {
        let parts = results.flatMap { result in
            let descriptions = describe(result, colored: colored)
            let identities = Self.includesOutputV2Identity ? outputV2Identities(of: result).map { Optional($0) } : Array(repeating: nil, count: descriptions.count)
            return zip(descriptions, identities).map { Part(location: $0.0, message: $0.1, identity: $1) }
        }
        return [
            "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<checkstyle version=\"4.3\">",
            parts
                .group(by: { outputPath($0.location).string.escapedForXML() })
                .sorted(by: { $0.key < $1.key })
                .map(generateForFile).joined(),
            "\n</checkstyle>",
        ].joined()
    }

    // MARK: - Private

    private func generateForFile(_ file: String, results: [Part]) -> String {
        [
            "\n\t<file name=\"", file, "\">\n",
            results.map(generateForResult).joined(),
            "\t</file>",
        ].joined()
    }

    private func generateForResult(_ result: Part) -> String {
        let line = result.location.line
        let col = result.location.column
        let identity = result.identity.map { "source=\"\($0.rule.rawValue)\" id=\"\($0.id)\" " } ?? ""

        return [
            "\t\t<error line=\"\(line)\" ",
            "column=\"\(col)\" ",
            "severity=\"warning\" ",
            identity,
            "message=\"", result.message.escapedForXML(), "\"/>\n",
        ].joined()
    }
}

/// `checkstyle-v2`: the `checkstyle` format, each error with the rule of its result as `source` and its output v2 id
/// as `id`.
final class CheckstyleV2Formatter: CheckstyleFormatter {
    override static var includesOutputV2Identity: Bool {
        true
    }
}
