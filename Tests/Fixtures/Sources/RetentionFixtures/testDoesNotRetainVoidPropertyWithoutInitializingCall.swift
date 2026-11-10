import Foundation

enum FixtureLazyEffects {
    static func runForStatic() {}
    static func runForLazy() {}
    static func runForGlobal() {}
    static func runForComputed() {}
    static func makeValue() -> Int { 1 }
    static let lazyOnce: Void = runForLazyRead()
    static func runForLazyRead() {}
}

let fixtureGlobalEffect: Void = FixtureLazyEffects.runForGlobal()

public class FixtureLazyEffectOwner {
    private static let staticEffect: Void = FixtureLazyEffects.runForStatic()
    private lazy var lazyEffect: Void = FixtureLazyEffects.runForLazy()
    private lazy var lazyReadEffect: Void = FixtureLazyEffects.lazyOnce
    private let literalEffect: Void = ()
    private var unassignedEffect: Void
    private let unreadValue: Int = FixtureLazyEffects.makeValue()
    private var computedEffect: Void {
        FixtureLazyEffects.runForComputed()
    }

    public init() {
        unassignedEffect = ()
    }
}
