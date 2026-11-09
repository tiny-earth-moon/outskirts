import SourceGraph

/// The targets selected for a fix run, less those that a guard keeps before planning, with the reason of each.
public struct GuardedTargets {
    private var candidates: [(target: FixTarget, declaration: Declaration)]
    fileprivate private(set) var skipped: [FixPlan.Skip] = []

    /// The selected targets, each with the declaration of its result.
    public init(_ candidates: [(target: FixTarget, declaration: Declaration)]) {
        self.candidates = candidates
    }

    /// The targets left to plan.
    public var targets: [FixTarget] {
        candidates.map(\.target)
    }

    /// Keeps the targets of the restrictive rules that code in an `#if` clause no scanned build compiled may use.
    public mutating func keepUncoveredConditionalUses(in graph: SourceGraph) throws {
        guard candidates.contains(where: \.target.rule.isRestrictive) else { return }

        let uncovered = try UncoveredConditionalNames(graph: graph)
        keep { target, declaration in
            target.rule.isRestrictive ? uncovered.skipReason(for: declaration, rule: target.rule) : nil
        }
    }

    /// Keeps the missing `final` of a class with an `open` member, declared in its body or in an extension of any file:
    /// a final class cannot have one, and the edit only sees the extensions of the class's own file.
    public mutating func keepClassesWithOpenMembers(in graph: SourceGraph) {
        keep { target, declaration in
            guard target.rule == .missingFinal, declaration.kind == .class else { return nil }

            let members = graph.extensions[declaration, default: []].reduce(into: declaration.declarations) { $0.formUnion($1.declarations) }
            return members.contains { $0.accessibility.value == .open } ? .openMember : nil
        }
    }

    /// Keeps the targets of the rules that need a scan of all the code, after a scan that left some out.
    public mutating func keepRulesRequiringACompleteScan(because reason: String) {
        keep { target, _ in
            target.rule.requiresCompleteScan ? .partialScan(reason) : nil
        }
    }

    /// Keeps the files of the modules the project does not declare, such as a local dependency package: its own tests
    /// and its other clients are not built, so they may use what the scan reports.
    public mutating func keepDependencyPackages(ownModules: Set<String>?) {
        guard let ownModules else { return }

        keep { _, declaration in
            declaration.location.file.modules.isDisjoint(with: ownModules) ? .dependencyPackage : nil
        }
    }

    /// Keeps the redundant `public` of the modules of a library product, whose clients outside the scan may use it.
    public mutating func keepLibraryProductAPI(modules: Set<String>?) {
        guard let modules else { return }

        keep { target, declaration in
            target.rule == .redundantPublic && !declaration.location.file.modules.isDisjoint(with: modules) ? .libraryProduct : nil
        }
    }

    // MARK: - Private

    private mutating func keep(where reason: (FixTarget, Declaration) -> SkipReason?) {
        candidates = candidates.filter { candidate in
            guard let reason = reason(candidate.target, candidate.declaration) else { return true }

            skipped.append(FixPlan.Skip(target: candidate.target, reason: reason))
            return false
        }
    }
}

public extension FixPlan {
    /// Records the targets that the guards kept before planning.
    mutating func addSkipped(_ guarded: GuardedTargets) {
        skipped += guarded.skipped
    }
}
