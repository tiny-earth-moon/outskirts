import Configuration
import Foundation

/// A result of the output v2. A redundant protocol is one result, its conformances are listed under `related`.
struct OutputV2Result {
    /// A position in a file whose path is relative to the project root. The end is the end of the declaration, nil
    /// when its extent is unknown.
    struct Location: Comparable {
        let path: String
        let line: Int
        let column: Int
        let endLine: Int?
        let endColumn: Int?

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.path, lhs.line, lhs.column) < (rhs.path, rhs.line, rhs.column)
        }
    }

    struct DeclarationInfo {
        let name: String
        let kind: String
        let accessibility: String
        let modules: [String]
        let usrs: [String]
    }

    struct Asset {
        let name: String?
        let paths: [String]
    }

    /// A result attached to another one: a conformance to a redundant protocol, with its conforming type.
    struct Related {
        let id: String
        let rule: RuleIdentifier
        let message: String
        let location: Location
        let declaration: DeclarationInfo?
    }

    let id: String
    let rule: RuleIdentifier
    let message: String
    let location: Location
    let declaration: DeclarationInfo
    let asset: Asset?
    /// The variants the result was found in, empty when it holds for every variant of the run.
    let variants: [String]
    let related: [Related]
    let fixable: Bool
}

extension OutputV2Result {
    var jsonObject: [String: Any] {
        [
            "id": id,
            "rule": rule.rawValue,
            "message": message,
            "location": location.jsonObject,
            "declaration": declaration.jsonObject,
            "asset": asset?.jsonObject ?? NSNull(),
            "variants": variants,
            "related": related.map(\.jsonObject),
            "fixable": fixable,
        ]
    }
}

extension OutputV2Result.Location {
    var jsonObject: [String: Any] {
        [
            "path": path,
            "line": line,
            "column": column,
            "endLine": endLine.map { $0 as Any } ?? NSNull(),
            "endColumn": endColumn.map { $0 as Any } ?? NSNull(),
        ]
    }
}

extension OutputV2Result.DeclarationInfo {
    var jsonObject: [String: Any] {
        ["name": name, "kind": kind, "accessibility": accessibility, "modules": modules, "usrs": usrs]
    }
}

extension OutputV2Result.Asset {
    var jsonObject: [String: Any] {
        ["name": name.map { $0 as Any } ?? NSNull(), "paths": paths]
    }
}

extension OutputV2Result.Related {
    var jsonObject: [String: Any] {
        [
            "id": id,
            "rule": rule.rawValue,
            "message": message,
            "location": location.jsonObject,
            "declaration": declaration?.jsonObject ?? NSNull(),
        ]
    }
}
