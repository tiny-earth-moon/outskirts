import Foundation

/// The frozen Periphery 3.8 surface in `Tests/Fixtures/Contract/periphery-3.8`, extracted once from the 3.8.0 release
/// (its `--experimental-dump-help`, its sources at the `3.8.0` tag and its output on `package/`).
///
/// The contract tests compare outskirts with these files. A failing contract test means that something Periphery 3.8
/// users rely on has changed: that is a 3.x compatibility break needing a deliberate decision, not a fixture update.
enum Periphery38Contract {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Periphery38
        .deletingLastPathComponent() // FrontendTests
        .deletingLastPathComponent() // Tests
        .appendingPathComponent("Fixtures/Contract/periphery-3.8")

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func decode<T: Decodable>(_: T.Type, from name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: url(name)))
    }
}

/// `cli.json`: the commands of 3.8 and their arguments.
struct Contract38CLI: Decodable {
    let commands: [Contract38Command]

    func command(_ name: String) -> Contract38Command? {
        commands.first { $0.name == name }
    }
}

struct Contract38Command: Decodable {
    let name: String
    let arguments: [Contract38Argument]
}

struct Contract38Argument: Decodable {
    let kind: String
    let names: [String]
    let repeating: Bool
    let parsing: String
    let values: [String]?
    let hidden: Bool?
    let valueName: String?
}

/// `configuration.json`: the keys of `.periphery.yml` in 3.8, their Swift type and the value `periphery.yml` sets.
struct Contract38ConfigurationKeys: Decodable {
    let keys: [String: Contract38Key]
    let removedBazelKeys: [String: Contract38RemovedKey]
}

struct Contract38Key: Decodable {
    let type: String
    let value: Contract38Value
    /// The value is a set: 3.8 loads it in no particular order.
    let unordered: Bool?
}

struct Contract38RemovedKey: Decodable {
    let type: String
}

enum Contract38Value: Decodable, Equatable, CustomStringConvertible {
    case bool(Bool)
    case string(String)
    case strings([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = try .strings(container.decode([String].self))
        }
    }

    var sorted: Self {
        guard case let .strings(values) = self else { return self }

        return .strings(values.sorted())
    }

    var description: String {
        switch self {
        case let .bool(value): "\(value)"
        case let .string(value): value
        case let .strings(values): "\(values)"
        }
    }
}

/// `exit-codes.json`: the exit statuses of 3.8.
struct Contract38ExitCodes: Decodable {
    let scan: Contract38ScanExitCodes
    let unknownSubcommand: Int32
}

struct Contract38ScanExitCodes: Decodable {
    let noResults: Int32
    let resultsWithoutStrict: Int32
    let resultsWithStrict: Int32
    let unknownOption: Int32
    let invalidOptionValue: Int32
    let missingConfigurationFile: Int32
}
