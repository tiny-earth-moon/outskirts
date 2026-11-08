protocol FixUnusedRequirementProtocol {
    func requirement()
}

public struct FixUnusedRequirementConformer: FixUnusedRequirementProtocol {
    public func requirement() {}
}
