import Configuration
import Logger
import SystemPackage

final class GitHubMarkdownFormatter: OutputFormatter {
    let configuration: Configuration
    let logger: Logger
    lazy var currentFilePath: FilePath = .current

    init(configuration: Configuration, logger: Logger) {
        self.logger = logger
        self.configuration = configuration
    }

    func format(_ results: [ScanResult], colored _: Bool) throws -> String? {
        guard !results.isEmpty else {
            return "No unused code detected."
        }

        let visibleResults = results.prefix(10).flatMap { format($0) }
        let expandableResults = results.dropFirst(10).flatMap { format($0) }
        let title = results.count == 1 ? "Result" : "Results"

        var markdown = """
        | \(results.count) \(title) |
        | :- |
        \(visibleResults.joined(separator: "\n"))
        """

        if !expandableResults.isEmpty {
            let expandableTitle = expandableResults.count == 1 ? "result" : "results"
            markdown += """

            <details>
              <summary>Show remaining \(expandableResults.count) \(expandableTitle)</summary>
              <br>

              | |
              | :- |
              \(expandableResults.joined(separator: "\n"))

            </details>
            """
        }

        return markdown
    }

    // MARK: - Private

    private func format(_ result: ScanResult) -> [String] {
        describe(result, colored: false).map { location, description in
            "| **\(escapeCell(description))**<br>\(escapeCell(locationDescription(location))) |"
        }
    }

    /// Makes a value inert in a table cell: line breaks become spaces, other control characters a visible escape,
    /// and the characters that open Markdown or HTML markup, a link or an autolink are backslash-escaped. An underscore
    /// inside a word cannot start emphasis, so `snake_case` names stay as they are.
    private func escapeCell(_ value: String) -> String {
        let characters = Array(
            value
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .withVisibleControlCharacters()
        )
        var escaped = ""

        for (index, character) in characters.enumerated() {
            switch character {
            case "\\", "`", "*", "[", "]", "<", ">", "~", "&", "|", "!", "#":
                escaped += "\\"
            case "_":
                let previous = index > characters.startIndex ? characters[index - 1] : nil
                let next = index + 1 < characters.endIndex ? characters[index + 1] : nil
                if previous?.isLetterOrNumber != true || next?.isLetterOrNumber != true {
                    escaped += "\\"
                }
            case ":" where characters[(index + 1)...].starts(with: ["/", "/"]):
                escaped += "\\"
            case "." where index >= 3 && String(characters[(index - 3) ..< index]).lowercased() == "www":
                escaped += "\\"
            default:
                break
            }
            escaped.append(character)
        }

        return escaped
    }
}

private extension Character {
    var isLetterOrNumber: Bool {
        isLetter || isNumber
    }
}
