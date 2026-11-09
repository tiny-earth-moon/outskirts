import Foundation

struct FixtureExactLabelsBootstrap {
    init(group _: Int) {}
    init(group _: Int, childGroup _: Int = 0) {}
}

struct FixtureExactLabelsDefaults {
    init() {}
    init(scale _: Int = 1) {}
}

struct FixtureExactLabelsFallback {
    init(group _: Int, childGroup _: Int = 0) {}
}

public func fixtureExactLabelsEntry() {
    _ = FixtureExactLabelsBootstrap.self
    _ = FixtureExactLabelsDefaults.self
    _ = FixtureExactLabelsFallback.self
    #if os(Linux)
    _ = FixtureExactLabelsBootstrap(group: 1)
    _ = FixtureExactLabelsDefaults()
    _ = FixtureExactLabelsFallback(group: 1)
    #endif
}
