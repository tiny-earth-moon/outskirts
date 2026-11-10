import Foundation

enum FixtureSideEffects {
    static func runForInstance() {}
    static func runForVariable() {}
    static func runInClosure() {}
    static func runForInferred() {}
    static func runOnceForStatic() {}
    static func runOnceForGlobal() {}
}

enum FixtureOneShot {
    static let runOnce: Void = {
        FixtureSideEffects.runOnceForStatic()
    }()
}

let fixtureGlobalOnce: Void = FixtureSideEffects.runOnceForGlobal()

public class FixtureSideEffectOwner {
    private let instanceEffect: Void = FixtureSideEffects.runForInstance()
    private var variableEffect: Swift.Void = FixtureSideEffects.runForVariable()
    private let closureEffect: () = {
        FixtureSideEffects.runInClosure()
    }()
    private let inferredEffect = FixtureSideEffects.runForInferred()
    private let staticReadEffect: Void = RetentionFixtures.FixtureOneShot.runOnce
    private let globalReadEffect: Void = fixtureGlobalOnce
}
