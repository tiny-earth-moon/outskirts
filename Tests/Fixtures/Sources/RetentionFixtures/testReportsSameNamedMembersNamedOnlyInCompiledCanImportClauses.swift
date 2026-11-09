import Foundation

public struct FixtureCanImportTarget {
    func canImportFoundationRun() {}
    func canImportProjectRun() {}
}

struct FixtureCanImportOther {
    func canImportFoundationRun() {}
    func canImportProjectRun() {}
}

public class FixtureCanImportUser {
    // The receiver is a parameter, whose type the clauses do not write.
    public func entry(target: FixtureCanImportTarget) {
        #if canImport(Foundation)
        target.canImportFoundationRun()
        #endif
        #if canImport(RetentionFixtures)
        target.canImportProjectRun()
        #endif
        _ = FixtureCanImportOther()
    }
}
