import Foundation

public struct FixtureExternalReceiverColors {
    func contains(_ value: Int) -> Bool { value > 0 }
}

extension Range where Bound == Int {
    func contains(fixtureValue: Int) -> Bool { contains(fixtureValue) }
}

public class FixtureExternalReceiverUser {
    public func entry() {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-fixture") else { return }
        _ = arguments.indices.contains(index + 1)
        #endif
    }
}
