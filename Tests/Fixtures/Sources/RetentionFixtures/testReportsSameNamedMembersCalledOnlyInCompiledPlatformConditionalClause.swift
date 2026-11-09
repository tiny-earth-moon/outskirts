struct FixtureCompiledClauseAlpha {
    func compiledClauseDraw() -> Int { 1 }
}

struct FixtureCompiledClauseBeta {
    func compiledClauseDraw() -> Int { 2 }
    func compiledClauseUnused() -> Int { 3 }
}

public struct FixtureCompiledClauseGamma {
    func compiledClausePaint() -> Int { 4 }
}

struct FixtureCompiledClauseDelta {
    func compiledClausePaint() -> Int { 5 }
}

public class FixtureCompiledClauseUser {
    // The receiver of the clause that was not compiled is a parameter, whose type the clause does not write.
    public func entry(gamma: FixtureCompiledClauseGamma) -> Int {
        var count = 0

        // The compiled clause is in the index store; the declaration in the other clause names no reference.
        #if os(macOS) || os(Linux)
        count += FixtureCompiledClauseAlpha().compiledClauseDraw()
        #else
        struct OtherPlatformDrawer {
            func compiledClauseDraw() -> Int { 0 }
        }
        #endif

        // A clause that was not compiled may call either member.
        #if os(iOS)
        count += gamma.compiledClausePaint()
        #endif

        _ = FixtureCompiledClauseBeta()
        _ = FixtureCompiledClauseDelta()
        return count
    }
}
