struct FixUnusedExtended {
    struct Nested {}
}

extension FixUnusedExtended {
    func more() {}
}

extension FixUnusedExtended.Nested {
    func nestedMore() {}
}

public func fixUnusedExtendedKept() {}
