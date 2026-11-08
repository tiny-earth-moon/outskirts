public final class FixUnusedMemberHolder {
    public init() {}

    func unusedMethod() {}

    subscript(index: Int) -> Int {
        index
    }

    var unusedComputed: Int {
        1
    }
}
