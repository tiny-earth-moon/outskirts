import Configuration
import Foundation
import Logger
import SourceGraph
import SystemPackage

class CsvFormatter: OutputFormatter {
    /// Whether each row starts with the output v2 id and rule of its result.
    class var includesOutputV2Identity: Bool { false }

    let configuration: Configuration
    let logger: Logger
    lazy var currentFilePath: FilePath = .current

    required init(configuration: Configuration, logger: Logger) {
        self.logger = logger
        self.configuration = configuration
    }

    func format(_ results: [ScanResult], colored _: Bool) -> String? {
        let header = "Kind,Name,Modifiers,Attributes,Accessibility,IDs,Location,Hints"
        var lines = [Self.includesOutputV2Identity ? "ID,Rule," + header : header]

        for result in results {
            var identities = Self.includesOutputV2Identity ? outputV2Identities(of: result)[...] : []
            let line = format(
                identity: identities.popFirst(),
                kind: declarationKind(from: result.declaration),
                name: result.declaration.name,
                modifiers: result.declaration.modifiers,
                attributes: result.declaration.attributes.mapSet(\.description),
                accessibility: result.declaration.accessibility.value.rawValue,
                usrs: result.declaration.usrs,
                location: declarationLocation(from: result.declaration),
                hint: describe(result.annotation)
            )
            lines.append(line)

            switch result.annotation {
            case let .redundantProtocol(references, inherited):
                for ref in sortedReferences(references) {
                    let line = format(
                        identity: identities.popFirst(),
                        kind: ref.declarationKind.rawValue,
                        name: ref.name,
                        modifiers: [],
                        attributes: [],
                        accessibility: nil,
                        usrs: [ref.usr],
                        location: ref.location,
                        hint: redundantConformanceHint(with: inherited)
                    )
                    lines.append(line)
                }
            default:
                break
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Private

    private func format(
        identity: (id: String, rule: RuleIdentifier)?,
        kind: String,
        name: String,
        modifiers: Set<String>,
        attributes: Set<String>,
        accessibility: String?,
        usrs: Set<String>,
        location: Location,
        hint: String?
    ) -> String {
        let joinedModifiers = modifiers.sorted().joined(separator: "|")
        let joinedAttributes = attributes.sorted().joined(separator: "|")
        let joinedUsrs = usrs.sorted().joined(separator: "|")
        let path = locationDescription(location)
        let identityFields = identity.map { [$0.id, $0.rule.rawValue] } ?? []
        return (identityFields + [
            kind,
            name,
            joinedModifiers,
            joinedAttributes,
            accessibility ?? "",
            joinedUsrs,
            path,
            hint ?? "",
        ]).map(escape).joined(separator: ",")
    }

    private func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") else {
            return field
        }

        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

/// `csv-v2`: the `csv` format, each row preceded by the output v2 id and rule of its result.
final class CsvV2Formatter: CsvFormatter {
    override class var includesOutputV2Identity: Bool { true }
}
