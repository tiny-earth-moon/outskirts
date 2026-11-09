import Foundation

struct FixtureScaledAmount {
    static func * (lhs: Self, _: Int) -> Self { lhs }
}

struct FixtureScaledLength {
    static func * (lhs: Self, _: Int) -> Self { lhs }
}

public func fixtureScaledEntry() {
    _ = FixtureScaledAmount()
    _ = FixtureScaledLength()
    #if os(iOS)
    _ = 2 * 3
    _ = FixtureScaledLength() * 2
    #endif
}
