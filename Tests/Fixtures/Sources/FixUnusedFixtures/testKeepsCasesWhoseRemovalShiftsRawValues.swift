enum FixUnusedRawValue: Int {
    case first
    case rawUnused
    case last
}

public func fixUnusedRawValueUser() {
    _ = [FixUnusedRawValue.first, .last]
}
