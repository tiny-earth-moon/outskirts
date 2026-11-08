enum FixUnusedEnum {
    case used
    case unusedCase
}

public func fixUnusedEnumUser() {
    _ = FixUnusedEnum.used
}
