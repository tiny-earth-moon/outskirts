struct Alpha {
    func draw() -> Int {
        1
    }
}

struct Beta {
    func draw() -> Int {
        2
    }
}

public func sameName() -> Int {
    var n = 0
    // Bound outside the clause, whose syntax then does not tell the receiver's type.
    let alpha = Alpha()
    #if os(iOS)
        n += alpha.draw()
    #endif
    _ = alpha
    _ = Beta()
    return n
}
