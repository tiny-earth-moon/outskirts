enum FixUnusedIterable: CaseIterable {
    case iterableUsed
    case iterableUnused
}

enum FixUnusedCodable: String, Codable {
    case codableUsed
    case codableUnused
}

public func fixUnusedEnumCasesUser() {
    _ = (FixUnusedIterable.iterableUsed, FixUnusedCodable.codableUsed)
}
