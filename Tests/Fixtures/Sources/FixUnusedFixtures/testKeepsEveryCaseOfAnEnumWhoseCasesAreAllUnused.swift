enum FixUnusedEmptiedEnum {
    case firstUnused
    case secondUnused
}

public func fixUnusedEmptiedEnumUser() {
    fixUnusedSwitch(over: nil)
}

func fixUnusedSwitch(over value: FixUnusedEmptiedEnum?) {
    switch value {
    case .none: break
    default: break
    }
}
