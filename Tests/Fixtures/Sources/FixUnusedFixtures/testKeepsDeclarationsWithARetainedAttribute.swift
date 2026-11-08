public final class FixUnusedRetainedHolder {
    public init() {}

    @discardableResult
    func unusedRetained() -> Int {
        1
    }
}
