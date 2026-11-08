struct FixUnusedType {
    func member() {}
}

typealias FixUnusedAlias = Int

protocol FixUnusedAssociatedTypeProtocol {
    associatedtype Unused
}

public func fixUnusedAssociatedTypeUser(_ value: Any) -> Bool {
    value is any FixUnusedAssociatedTypeProtocol
}
