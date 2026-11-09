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
