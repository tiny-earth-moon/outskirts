public final class FixUnusedEquatable: Equatable {
    public init() {}

    var unusedCompared = 1

    public static func == (lhs: FixUnusedEquatable, rhs: FixUnusedEquatable) -> Bool {
        true
    }
}
