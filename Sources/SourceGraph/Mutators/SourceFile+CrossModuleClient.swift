extension SourceFile {
    /// Whether the file belongs to a module other than `declaringModules` and is not a test file that
    /// `@testable import`s any of them: such a file needs `public` to use a declaration of those modules, and `open`
    /// to subclass or override it. A `@testable import` outside a test file only builds against a testing-enabled
    /// module, so it does not stand in for `public` in a release build.
    func isNonTestableClient(ofModules declaringModules: Set<String>) -> Bool {
        guard !modules.isSubset(of: declaringModules) else { return false }
        guard isTestFile else { return true }

        return !importStatements.contains { $0.isTestable && declaringModules.contains($0.module) }
    }

    private var isTestFile: Bool {
        importsSwiftTesting || importStatements.contains { $0.module == "XCTest" }
    }
}
