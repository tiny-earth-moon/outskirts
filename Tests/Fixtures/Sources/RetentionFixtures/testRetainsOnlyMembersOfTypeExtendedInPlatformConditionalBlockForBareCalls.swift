import Foundation

public struct FixtureBareCallA {
    func reset() {}
    func restart() {}
}

public struct FixtureBareCallB {
    func reset() {}
    func restart() {}
    func unrelatedFree() {}
}

func unrelatedFree() {}

#if os(iOS)
extension FixtureBareCallA {
    public func entryOnIOS() {
        reset()
        self.restart()
        unrelatedFree()
    }
}
#endif

public class FixtureBareCallBase {
    func inheritedReload() {}
}

public struct FixtureBareCallOther {
    func inheritedReload() {}
}

// The index store does not describe a class the clause declares: its superclass is unknown.
#if os(iOS)
class FixtureBareCallSub: FixtureBareCallBase {
    func entryOnIOS() {
        inheritedReload()
    }
}
#endif
