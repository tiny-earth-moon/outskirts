/// What the syntax of the `#if` clauses that the index store may lack tells about the declarations they use.
public struct PlatformConditionalNames: Equatable, Sendable {
    /// The names written as references, operators included, in the platform conditional clauses no indexed build
    /// compiled.
    public var references: Set<String> = []
    /// For each operator applied in a platform conditional clause that no indexed build compiles with certainty, the
    /// names written in the clauses that apply it: an operator member of a type is only retained when the type is named
    /// alongside it.
    public var operatorClauseNames: [String: Set<String>] = [:]
    /// The names of the members declared `override` in these clauses.
    public var overriddenNames: Set<String> = []
    /// The names written in the inheritance clause of the classes and protocols declared in these clauses.
    public var inheritedNames: Set<String> = []
    /// The names written in the `#if` blocks whose condition does not involve the platform (custom flags, `DEBUG`...),
    /// collected whole, compiled clause included. They only account for imports.
    public var otherClauseNames: Set<String> = []

    // The uses below are only collected from the clauses that no indexed build compiles, with certainty: a clause
    // that may be compiled is in the index store, which describes its unnamed uses exactly.

    /// The conformances declared by the extensions written in these clauses: the members of the type that implement a
    /// requirement of the protocol are its witnesses.
    public var conformances: Set<PlatformConditionalConformance> = []
    /// The initializers these clauses call without writing their name: `T(...)`, `T.init(...)`, `let value: T =
    /// .init(...)`, or `T.self`.
    public var constructions: Set<PlatformConditionalConstruction> = []
    /// The names written in the clauses that access a value with `[ ]`: the subscripts of a type named there may be
    /// called.
    public var subscriptedNames: Set<String> = []
    /// The names written in the clauses that call a value directly, `value()`: the `callAsFunction` of a type named
    /// there may be called.
    public var valueCalledNames: Set<String> = []

    public init() {}

    public var isEmpty: Bool {
        references.isEmpty && operatorClauseNames.isEmpty && overriddenNames.isEmpty && inheritedNames.isEmpty
            && otherClauseNames.isEmpty && conformances.isEmpty && constructions.isEmpty && subscriptedNames.isEmpty
            && valueCalledNames.isEmpty
    }
}

/// A conformance declared by an extension written in a platform conditional clause.
public struct PlatformConditionalConformance: Hashable, Sendable {
    let typeName: String
    let protocolName: String

    public init(typeName: String, protocolName: String) {
        self.typeName = typeName
        self.protocolName = protocolName
    }
}

/// An initializer call written in a platform conditional clause without the name of the initializer.
public struct PlatformConditionalConstruction: Hashable, Sendable {
    let typeName: String
    /// The argument labels of the call, `_` for an unlabeled argument, or nil when they cannot be read (`T.self`,
    /// `T.init` unapplied).
    let labels: [String]?

    public init(typeName: String, labels: [String]?) {
        self.typeName = typeName
        self.labels = labels
    }

    /// Whether the call may reach the initializer of this name, `init(value:_:)`. A parameter missing from the call
    /// may have a default value and an unlabeled argument following another may fill the same variadic parameter, as
    /// the graph does not record either.
    func matches(initializerName: String) -> Bool {
        guard let labels else { return true }

        let parameterLabels = Self.parameterLabels(of: initializerName)
        var nextParameter = parameterLabels.startIndex
        var hasMatched = false

        for label in labels {
            if let index = parameterLabels[nextParameter...].firstIndex(of: label) {
                nextParameter = parameterLabels.index(after: index)
                hasMatched = true
            } else if label != "_" || !hasMatched {
                return false
            }
        }

        return true
    }

    private static func parameterLabels(of declarationName: String) -> [String] {
        guard let open = declarationName.firstIndex(of: "("), let close = declarationName.lastIndex(of: ")") else {
            return []
        }

        return declarationName[declarationName.index(after: open) ..< close]
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
    }
}
