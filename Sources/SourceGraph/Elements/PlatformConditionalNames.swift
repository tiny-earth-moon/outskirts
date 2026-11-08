/// What the syntax of the `#if` clauses that the index store may lack tells about the declarations they use.
public struct PlatformConditionalNames: Equatable, Sendable {
    /// The names written as references, operators included, in the platform conditional clauses no indexed build
    /// compiled.
    public var references: Set<String> = []
    /// The conformances declared by the extensions written in these clauses: the members of the type that implement a
    /// requirement of the protocol are its witnesses.
    public var conformances: Set<PlatformConditionalConformance> = []
    /// The names of the members declared `override` in these clauses.
    public var overriddenNames: Set<String> = []
    /// The names written in the inheritance clause of the classes and protocols declared in these clauses.
    public var inheritedNames: Set<String> = []
    /// The names written in the `#if` blocks whose condition does not involve the platform (custom flags, `DEBUG`...),
    /// collected whole, compiled clause included. They only account for imports.
    public var otherClauseNames: Set<String> = []

    public init() {}

    public var isEmpty: Bool {
        references.isEmpty && conformances.isEmpty && overriddenNames.isEmpty && inheritedNames.isEmpty
            && otherClauseNames.isEmpty
    }
}

/// A conformance declared by an extension written in a platform conditional clause.
public struct PlatformConditionalConformance: Hashable, Sendable {
    public let typeName: String
    public let protocolName: String

    public init(typeName: String, protocolName: String) {
        self.typeName = typeName
        self.protocolName = protocolName
    }
}
