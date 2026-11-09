import Foundation

public protocol FixtureConditionalRequirement01 {
    #if !canImport(Foundation)
    func unavailable(value: Int)
    #else
    init(seed: Int)
    func evaluate(_ trust: Int, forHost host: String) throws
    #endif
}

public final class FixtureConditionalRequirement01Used: FixtureConditionalRequirement01 {
    public init() {}
    public init(seed: Int) {
        print(seed)
    }

    public func evaluate(_ trust: Int, forHost host: String) throws {
        print(trust, host)
    }
}

public final class FixtureConditionalRequirement01Empty: FixtureConditionalRequirement01 {
    public init() {}
    public init(seed: Int) {}
    public func evaluate(_ trust: Int, forHost host: String) throws {}
}

public protocol FixtureConditionalRequirement02 {
    #if os(macOS) || os(Linux)
    #if canImport(Foundation)
    func nested(param: String)
    #endif
    #endif
}

public final class FixtureConditionalRequirement02Used: FixtureConditionalRequirement02 {
    public init() {}
    public func nested(param: String) {
        print(param)
    }
}

public final class FixtureConditionalRequirement02Empty: FixtureConditionalRequirement02 {
    public init() {}
    public func nested(param: String) {}
}

#if canImport(Foundation)
public protocol FixtureConditionalRequirement03 {
    func wrapped(param: String)
}

public final class FixtureConditionalRequirement03Used: FixtureConditionalRequirement03 {
    public init() {}
    public func wrapped(param: String) {
        print(param)
    }
}

public final class FixtureConditionalRequirement03Empty: FixtureConditionalRequirement03 {
    public init() {}
    public func wrapped(param: String) {}
}
#endif
