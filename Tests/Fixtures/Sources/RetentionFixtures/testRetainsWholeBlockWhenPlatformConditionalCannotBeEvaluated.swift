import Foundation

public struct FixtureUnevaluatedFlagAlpha { func unevaluatedFlag() {} }
struct FixtureUnevaluatedFlagBeta { func unevaluatedFlag() {} }
public struct FixtureUnevaluatedImportAlpha { func unevaluatedImport() {} }
struct FixtureUnevaluatedImportBeta { func unevaluatedImport() {} }
public struct FixtureUnevaluatedVersionAlpha { func unevaluatedVersion() {} }
struct FixtureUnevaluatedVersionBeta { func unevaluatedVersion() {} }
public struct FixtureUnevaluatedNestedAlpha { func unevaluatedNested() {} }
struct FixtureUnevaluatedNestedBeta { func unevaluatedNested() {} }
public struct FixtureUnevaluatedInnerAlpha { func unevaluatedInner() {} }
struct FixtureUnevaluatedInnerBeta { func unevaluatedInner() {} }

public class FixtureUnevaluatedUser {
    // The receivers are parameters, whose type the clauses do not write: every same-named member stays retained.
    public func entry(
        flag: FixtureUnevaluatedFlagAlpha,
        importing: FixtureUnevaluatedImportAlpha,
        version: FixtureUnevaluatedVersionAlpha,
        nested: FixtureUnevaluatedNestedAlpha,
        inner: FixtureUnevaluatedInnerAlpha
    ) {
        #if FIXTURE_UNDEFINED_FLAG || os(macOS) || os(Linux)
        flag.unevaluatedFlag()
        #endif

        #if canImport(Foundation)
        importing.unevaluatedImport()
        #endif

        #if (os(macOS) || os(Linux)) && swift(>=5.0)
        version.unevaluatedVersion()
        #endif

        #if FIXTURE_UNDEFINED_FLAG
        #if os(macOS) || os(Linux)
        nested.unevaluatedNested()
        #endif
        #endif

        #if os(macOS) || os(Linux)
        #if arch(arm64) || arch(x86_64)
        inner.unevaluatedInner()
        #endif
        #endif

        _ = FixtureUnevaluatedFlagBeta()
        _ = FixtureUnevaluatedImportBeta()
        _ = FixtureUnevaluatedVersionBeta()
        _ = FixtureUnevaluatedNestedBeta()
        _ = FixtureUnevaluatedInnerBeta()
    }
}
