import Foundation

infix operator <~>
infix operator <~~>

struct FixtureUnnamedUseType {
    init(value _: Int) {}
    subscript(index: Int) -> Int { index }
    func callAsFunction() {}
}

struct FixtureUnnamedUseDistractor {
    init(value _: Int) {}
    subscript(index: Int) -> Int { index }
    func callAsFunction() {}
}

struct FixtureUnnamedUseOperand {
    static func <~> (_: Self, _: Self) -> Bool { true }
    static func <~~> (_: Self, _: Self) -> Bool { true }
}

protocol FixtureUnnamedUseProtocol {
    func fixtureUnnamedUseRequirement()
}

struct FixtureUnnamedUseConformer {
    func fixtureUnnamedUseRequirement() {}
    func fixtureUnnamedUseNonRequirement() {}
}

struct FixtureUnnamedUseNonConformer {
    func fixtureUnnamedUseRequirement() {}
}

#if os(iOS)
extension FixtureUnnamedUseConformer: FixtureUnnamedUseProtocol {}
#endif

public func fixtureUnnamedUseEntry() {
    _ = FixtureUnnamedUseDistractor.self
    _ = FixtureUnnamedUseConformer.self
    _ = FixtureUnnamedUseNonConformer.self
    #if os(iOS)
    let value = FixtureUnnamedUseType(value: 0)
    _ = value[0]
    value()
    _ = FixtureUnnamedUseOperand() <~> FixtureUnnamedUseOperand()
    #endif
}
