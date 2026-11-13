import Foundation

final class FixtureClass1800Cache {
    var stored = 0

    subscript(key: String) -> Int {
        get { key.count }
        set { print(key, newValue) }
    }
}

protocol FixtureProtocol1800: AnyObject {
    subscript(key: String) -> Int { get set }
}

extension FixtureClass1800Cache: FixtureProtocol1800 {}

struct FixtureStruct1800Box {
    var values: [String: Int] = [:]

    subscript(key: String) -> Int {
        get { values[key] ?? 0 }
        nonmutating set { print(key, newValue) }
    }
}

let fixtureGlobalLetCache1800 = FixtureClass1800Cache()

public class FixtureClass1800 {
    static let staticLetCache = FixtureClass1800Cache()
    let instanceLetCache = FixtureClass1800Cache()
    let initAssignedLetCache: FixtureClass1800Cache
    let existentialLetCache: any FixtureProtocol1800 = FixtureClass1800Cache()
    let nonmutatingLetBox = FixtureStruct1800Box()
    let memberLetCache = FixtureClass1800Cache()
    let (tupleLetCacheA, tupleLetCacheB) = (FixtureClass1800Cache(), FixtureClass1800Cache())
    var varCache = FixtureClass1800Cache()
    var memberVarCache = FixtureClass1800Cache()
    weak var weakCache: FixtureClass1800Cache?
    let unreadInitAssignedLet: Int
    var unreadReassignedVarCache = FixtureClass1800Cache()

    init() {
        initAssignedLetCache = FixtureClass1800Cache()
        unreadInitAssignedLet = 1
    }

    public func run() {
        fixtureGlobalLetCache1800["a"] = 1
        FixtureClass1800.staticLetCache["b"] = 2
        instanceLetCache["c"] = 3
        initAssignedLetCache["d"] = 4
        existentialLetCache["e"] = 5
        nonmutatingLetBox["f"] = 6
        memberLetCache.stored = 7
        tupleLetCacheA["j"] = 12
        tupleLetCacheB["k"] = 13
        varCache["g"] = 8
        memberVarCache.stored = 9
        weakCache?["h"] = 10
        unreadReassignedVarCache = FixtureClass1800Cache()
    }
}
