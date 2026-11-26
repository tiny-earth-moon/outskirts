public protocol LayerGreeting {
    func greetingText() -> String
}

extension LayerGreeting {
    public func greetingText() -> String { "hello" }
}

public protocol LayerFarewell {
    func farewellText() -> String
}
