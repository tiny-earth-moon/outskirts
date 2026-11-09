struct Gamma {
    @available(iOS, unavailable)
    func macOnlyNeverCalled() -> Int {
        6
    }

    @available(iOS, unavailable)
    func macOnlyCalled() -> Int {
        7
    }
}

struct Delta {
    func paint() -> Int {
        8
    }
}

struct Epsilon {
    func paint() -> Int {
        9
    }
}

public func covered() -> Int {
    var n = 0
    // Bound outside the clauses, whose syntax then does not tell the receiver's type.
    let delta = Delta()
    #if os(macOS)
        n += Gamma().macOnlyCalled()
    #endif
    #if os(iOS)
        #if targetEnvironment(simulator)
            n += delta.paint()
        #endif
    #endif
    _ = delta
    _ = Epsilon()
    return n
}
