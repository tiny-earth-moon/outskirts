class FixUnusedUncoveredBase {
    init() {}
    func fixUnusedHook() {}
}

struct FixUnusedOnlyExtendedInRelease {}

struct FixUnusedDescribed {
    var description: String { "described" }
}

struct FixUnusedGrid {
    subscript(index: Int) -> Int { index }
}

func fixUnusedNotReached() {}

public func fixUnusedUncoveredReachUser() {
    _ = FixUnusedUncoveredBase()
    _ = FixUnusedDescribed()
    _ = FixUnusedGrid()
}

#if !DEBUG
    class FixUnusedUncoveredSub: FixUnusedUncoveredBase {
        override func fixUnusedHook() {}
    }

    extension FixUnusedOnlyExtendedInRelease {
        func fixUnusedReleaseHelper() {}
    }

    extension FixUnusedDescribed: CustomStringConvertible {}
#endif
