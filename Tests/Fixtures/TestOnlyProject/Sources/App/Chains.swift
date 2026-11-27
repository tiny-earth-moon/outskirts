struct ChainEntry {
    func start() {
        ChainMiddle().step()
    }
}

struct ChainMiddle {
    func step() {
        ChainLeaf().finish()
    }
}

struct ChainLeaf {
    func finish() {}
}

protocol Describing {
    func describeForTests() -> String
}

struct Report: Describing {
    func describeForTests() -> String {
        "report"
    }
}

struct LegacyEncoder {
    func encode() {}
}
