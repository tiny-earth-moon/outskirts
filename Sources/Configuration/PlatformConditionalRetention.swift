/// How declarations that may be used by a build the index store does not contain are retained.
public enum PlatformConditionalRetention: String, CaseIterable, Equatable, Sendable {
    /// Like `allClauses`, also narrowing `#if` blocks nested in another one, and not retaining a declaration marked
    /// `@available(X, unavailable)` once the index holds a build for `X` and one for a platform where it is available.
    case auto
    /// Retain the declarations marked `@available(X, unavailable)`, and what the platform `#if` clauses no indexed
    /// build compiles, with certainty, use precisely: the members of the types their receivers are proven to be, the
    /// initializers, subscripts and `callAsFunction` they call without naming them, the operators of the types they
    /// name, and the witnesses of the conformances they declare. A name alone retains nothing.
    case allClauses = "all-clauses"
    /// Like `allClauses`, also retaining every declaration of the names written bare or on a receiver of unknown type in
    /// the platform `#if` clauses no indexed build compiled (nested blocks whole): the retention of outskirts 3.21
    /// and earlier.
    case names
    /// Retain neither.
    case off

    public static let `default` = PlatformConditionalRetention.allClauses

    /// Whether the names written in the clauses retain every declaration of the name, whatever its type.
    public var retainsNames: Bool {
        self == .names
    }
}
