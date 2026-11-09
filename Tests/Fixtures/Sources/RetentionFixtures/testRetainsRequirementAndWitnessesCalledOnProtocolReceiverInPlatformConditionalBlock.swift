import Foundation

protocol FixtureProtocolReceiver {
    func contains(_ value: Int) -> Bool
}

public struct FixtureProtocolReceiverWitness: FixtureProtocolReceiver {
    func contains(_ value: Int) -> Bool { value > 0 }
}

public struct FixtureProtocolReceiverUnrelated {
    func contains(_ value: Int) -> Bool { value < 0 }
}

public class FixtureProtocolReceiverUser {
    public func entry() {
        #if os(iOS)
        func check(_ subject: any FixtureProtocolReceiver) -> Bool { subject.contains(1) }
        _ = check(FixtureProtocolReceiverWitness())
        #endif
    }
}
