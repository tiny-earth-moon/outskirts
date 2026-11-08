/// What the syntax of an `#if` clause that the index store may lack tells about the declarations it uses.
///
/// The collector hands these over as strings: a reference is the name itself, the other entries are encoded with a
/// backtick, which no identifier, raw ones included, contains.
public enum PlatformConditionalName: Hashable, Sendable {
    /// A name written as a reference in a platform conditional clause.
    case reference(String)
    /// `extension <type>: <protocol>` written in a platform conditional clause: the members of the type that
    /// implement a requirement of the protocol are its witnesses.
    case conformance(type: String, protocol: String)
    /// The name of a member declared `override` in a platform conditional clause.
    case override(String)
    /// A name written in the inheritance clause of a class or protocol declared in a platform conditional clause.
    case superclass(String)
    /// A name written in a clause of an `#if` block whose condition does not involve the platform (custom flags,
    /// `DEBUG`...). It only accounts for imports: the block is collected whole, compiled clause included.
    case otherClauseReference(String)

    private static let marker: Character = "`"

    public var encoded: String {
        switch self {
        case let .reference(name):
            name
        case let .conformance(type, `protocol`):
            Self.encode("conformance", type, `protocol`)
        case let .override(name):
            Self.encode("override", name)
        case let .superclass(name):
            Self.encode("superclass", name)
        case let .otherClauseReference(name):
            Self.encode("other", name)
        }
    }

    public init?(encoded: String) {
        guard encoded.first == Self.marker else {
            guard !encoded.isEmpty else { return nil }

            self = .reference(encoded)
            return
        }

        let parts = encoded.dropFirst().split(separator: Self.marker, omittingEmptySubsequences: false).map(String.init)

        switch (parts.first, parts.count) {
        case ("conformance", 3):
            self = .conformance(type: parts[1], protocol: parts[2])
        case ("override", 2):
            self = .override(parts[1])
        case ("superclass", 2):
            self = .superclass(parts[1])
        case ("other", 2):
            self = .otherClauseReference(parts[1])
        default:
            return nil
        }
    }

    private static func encode(_ kind: String, _ values: String...) -> String {
        ([String(marker) + kind] + values).joined(separator: String(marker))
    }
}

/// A conformance declared by an extension written in a platform conditional clause.
public struct PlatformConditionalConformance: Hashable, Sendable {
    public let typeName: String
    public let protocolName: String
}
