import Foundation

// A C call written bare in a clause no build compiles (swift-nio).
struct FixtureNameOnlyChannel {
    func write(_: Int) {}
}

struct FixtureNameOnlyFile {
    func write(_: Int) {}
}

// A member written on a receiver whose type the clause does not prove (Satin).
struct FixtureNameOnlyMaterial {
    func set(_: String, _: Float) {}
}

struct FixtureNameOnlyShader {
    func set(_: String, _: Float) {}
}

// Members written in clauses that a build may compile (The Composable Architecture).
struct FixtureNameOnlyTestStore {
    func receive(_: Int) {}
    func scope() {}
}

// Locals named like members, in a clause no build compiles (The Composable Architecture).
struct FixtureNameOnlyStore {
    var state: Int { 0 }
    func send(_: Int) {}
}

struct FixtureNameOnlyController {
    var state: Int { 0 }

    func render(send: (Int) -> Void) {
        #if canImport(UIKit)
        let state = 1
        send(state)
        #endif
    }
}

private func fixtureNameOnlyPrintError() {
    "".withCString { buffer in
        #if os(Windows)
        _ = write(2, buffer, 0)
        #else
        _ = buffer
        #endif
    }
}

private func fixtureNameOnlyApply(_ material: Any) {
    #if os(iOS)
    material.set("depth", 1)
    #endif
}

/// Compiled when the clauses are: the receiver is a parameter, whose type the clauses do not prove.
struct FixtureNameOnlyTestDouble {
    func receive(_: Int) {}
    func scope() {}
}

private func fixtureNameOnlyTest(_ store: FixtureNameOnlyTestDouble) {
    #if canImport(Testing)
    store.receive(1)
    #endif
    #if DEBUG && !os(visionOS)
    store.scope()
    #endif
}

public func fixtureNameOnlyEntry() {
    _ = FixtureNameOnlyChannel()
    _ = FixtureNameOnlyFile()
    _ = FixtureNameOnlyMaterial()
    _ = FixtureNameOnlyShader()
    _ = FixtureNameOnlyTestStore()
    _ = FixtureNameOnlyStore()
    FixtureNameOnlyController().render { _ in }
    fixtureNameOnlyPrintError()
    fixtureNameOnlyApply(0)
    fixtureNameOnlyTest(FixtureNameOnlyTestDouble())
}
