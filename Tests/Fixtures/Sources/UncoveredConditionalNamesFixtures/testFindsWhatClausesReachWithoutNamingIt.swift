class ConditionalUncoveredBase {
    init() {}
    func conditionalHook() {}
}

struct ConditionalOnlyExtendedInRelease {}

struct ConditionalDescribed {
    var description: String { "described" }
}

struct ConditionalGrid {
    subscript(index: Int) -> Int { index }
}

func conditionalNotReached() {}

public func conditionalReachUser() {
    _ = ConditionalUncoveredBase()
    _ = ConditionalDescribed()
    _ = ConditionalGrid()
}

#if !DEBUG
    class ConditionalUncoveredSub: ConditionalUncoveredBase {
        override func conditionalHook() {}
    }

    extension ConditionalOnlyExtendedInRelease {
        func conditionalReleaseHelper() {}
    }

    extension ConditionalDescribed: CustomStringConvertible {}
#endif
