import Foundation

extension SourceGraph {
    public func addConditionalCompilationNames(_ names: Set<String>) {
        conditionalCompilationNames.formUnion(names)
    }

    /// Retains the declaration for a reason that only code in test files gives. Unless another reason retains it,
    /// before or after, it is not a root of the walk from the code outside test files.
    func markRetainedForTestsOnly(_ declaration: Declaration, reason: @autoclosure () -> RetentionReason) {
        if recordsExplanations {
            recordRetentionReason(reason(), for: declaration)
        }

        guard !isRetained(declaration) else { return }

        markRetained(declaration)
        retainedForTestsOnly.insert(declaration)
    }

    func markTestOnly(_ declaration: Declaration, entry: Declaration) {
        testOnlyEntries[declaration] = entry
        if declaration == entry {
            testOnlyDeclarations.insert(declaration)
        }
    }
}
