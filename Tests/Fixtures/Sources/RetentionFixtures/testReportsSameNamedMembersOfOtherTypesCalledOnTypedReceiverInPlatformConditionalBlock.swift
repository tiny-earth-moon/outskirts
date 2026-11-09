import Foundation

public struct FixtureTypedReceiverA {
    func contains(_ value: Int) -> Bool { value > 0 }
    static func make() -> Bool { true }
    func annotatedUse() {}
}

public struct FixtureTypedReceiverB {
    func contains(_ value: Int) -> Bool { value < 0 }
    static func make() -> Bool { false }
    func annotatedUse() {}
}

public class FixtureTypedReceiverUser {
    public func entry() {
        #if os(iOS)
        _ = FixtureTypedReceiverA().contains(1)
        _ = FixtureTypedReceiverA.make()
        let value: FixtureTypedReceiverA? = nil
        value?.annotatedUse()
        #endif
    }
}
