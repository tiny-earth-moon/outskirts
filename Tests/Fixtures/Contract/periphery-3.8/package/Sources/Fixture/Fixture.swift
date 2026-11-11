struct UnusedFixtureType {}

protocol RedundantMarker {}

public struct Helper {
    public init() {}
}

public struct Entry: RedundantMarker {
    public init() {
        _ = Helper()
    }

    public func run(_ unusedParameter: Int) {}
}
