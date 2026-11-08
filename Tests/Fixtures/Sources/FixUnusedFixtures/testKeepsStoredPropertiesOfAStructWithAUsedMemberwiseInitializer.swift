struct FixUnusedMemberwise {
    let used: Int
    let unusedConstant = 1
}

public func fixUnusedMemberwiseUser() -> Int {
    FixUnusedMemberwise(used: 1).used
}
