import Configuration
import PeripheryKit
import SourceGraph

/// The unused declarations that `fix --rule unused` removes, and why the others are kept.
///
/// A declaration stays in the set only while nothing that is kept references it or one of its descendants, every
/// extension of it and of its descendants is removed with it, and, for a protocol requirement, every declaration that
/// implements it is removed too. Each kept declaration can keep others, so the set is reduced until it is stable,
/// and again whenever the planner keeps one of its targets.
public struct UnusedRemovalSet {
    /// The targets that were kept, with the reason of each.
    private(set) var skipped: [(target: FixTarget, reason: SkipReason)] = []

    private let graph: SourceGraph
    private var removed: [Declaration: FixTarget] = [:]
    /// The extensions reported with an unused type, and the type each extends.
    private var extensionCandidates: [Declaration: (target: FixTarget, extended: Declaration)] = [:]
    private var removedExtensions: [Declaration: FixTarget] = [:]

    private static let removableKinds: Set<Declaration.Kind> = [
        .functionFree, .functionMethodClass, .functionMethodInstance, .functionMethodStatic, .functionOperator,
        .functionOperatorInfix, .functionOperatorPostfix, .functionOperatorPrefix, .functionSubscript,
        .varGlobal, .varInstance, .varStatic, .varClass,
        .class, .struct, .enum, .protocol, .typealias, .enumelement, .associatedtype,
    ]
    private static let typeKinds: Set<Declaration.Kind> = [.class, .struct, .enum, .protocol]
    private static let excludedModifiers = ["override", "dynamic"]
    private static let excludedAttributes = [
        "objc", "main", "_cdecl", "_silgen_name", "IBAction", "IBOutlet", "IBInspectable", "IBSegueAction",
        "NSManaged", "GKInspectable", "_dynamicReplacement",
    ]
    private static let codableProtocols: Set<String> = ["Codable", "Decodable", "Encodable"]
    /// Protocols outside the scan known not to imply a conformance synthesized from the stored properties.
    private static let nonSynthesizingExternalProtocols: Set<String> = [
        "Sendable", "Error", "Identifiable", "CustomStringConvertible", "CustomDebugStringConvertible", "View",
        "ObservableObject", "App", "Scene", "PreviewProvider",
    ]

    /// - Parameter results: the reported results; only unused declarations are considered.
    /// - Parameter uncoveredNames: the names written in the `#if` clauses no scanned build compiled, which keep the
    ///   declarations they may reference.
    /// - Parameter includesPublic: whether `public` and `open` declarations may be removed, unless the configuration
    ///   retains them.
    /// - Parameter includesStoredProperties: whether stored instance properties may be removed, which changes the
    ///   memory layout of their type.
    /// - Parameter ownModules: the modules of the targets the project builds, when the driver knows them: the files
    ///   of other modules, such as a local dependency package, are not edited, as their own tests are not built.
    public init(
        results: [ScanResult],
        graph: SourceGraph,
        configuration: Configuration,
        uncoveredNames: UncoveredConditionalNames = UncoveredConditionalNames(names: []),
        includesPublic: Bool = false,
        includesStoredProperties: Bool = false,
        ownModules: Set<String>? = nil
    ) throws {
        self.graph = graph
        let eligibility = Eligibility(
            retentionRules: try AttributeRetentionRule.resolve(configuration),
            configuration: configuration,
            uncoveredNames: uncoveredNames,
            includesPublic: includesPublic,
            includesStoredProperties: includesStoredProperties
        )

        var extendedTypes: [Declaration: Declaration] = [:]
        for (type, extensions) in graph.extensions {
            for extensionDecl in extensions {
                extendedTypes[extensionDecl] = type
            }
        }

        let unusedResults = results
            .filter(\.isUnusedDeclaration)
            .compactMap { result in FixTarget(result: result).map { (declaration: result.resultDeclaration, target: $0) } }
            .sorted { Self.isOrdered($0.target, before: $1.target) }

        for (declaration, target) in unusedResults {
            if target.hasLocationOverride {
                skipped.append((target, .locationOverride))
            } else if let ownModules, declaration.location.file.modules.isDisjoint(with: ownModules) {
                skipped.append((target, .dependencyPackage))
            } else if declaration.kind.isExtensionKind {
                guard let extended = extendedTypes[declaration] else {
                    skipped.append((target, .unremovableKind))
                    continue
                }

                extensionCandidates[declaration] = (target, extended)
            } else if let reason = ineligibility(of: declaration, eligibility) {
                skipped.append((target, reason))
            } else {
                removed[declaration] = target.refusingStoredProperty(storedPropertyRefusal(of: declaration, eligibility))
            }
        }
        reduce()
    }

    /// The targets to remove: the declarations and the extensions of the removed types.
    var targets: [FixTarget] {
        (Array(removed.values) + Array(removedExtensions.values)).sorted { Self.isOrdered($0, before: $1) }
    }

    /// Keeps the given targets, which the planner could not remove, and every declaration that can no longer be
    /// removed without them. Returns whether the set changed.
    @discardableResult
    mutating func keep(_ kept: [(target: FixTarget, reason: SkipReason)]) -> Bool {
        let keptTargets = Set(kept.map(\.target))
        let removedBefore = removed.count + removedExtensions.count

        for (declaration, target) in removed where keptTargets.contains(target) {
            removed[declaration] = nil
        }
        for (declaration, candidate) in extensionCandidates where keptTargets.contains(candidate.target) {
            extensionCandidates[declaration] = nil
            removedExtensions[declaration] = nil
        }
        skipped += kept.filter { $0.target.rule == .unused }
        reduce()
        return removed.count + removedExtensions.count != removedBefore
    }

    // MARK: - Private

    /// Removes from the set every declaration that something kept still needs, until the set is stable.
    private mutating func reduce() {
        var isStable = false
        while !isStable {
            isStable = true
            removedExtensions = extensionCandidates.filter { isInRemovedDeclaration($0.value.extended) }.mapValues(\.target)
            if keepCasesOfEnumsLeftEmpty() {
                isStable = false
            }

            for declaration in removed.keys.sorted(by: { Self.isOrdered(removed[$0]!, before: removed[$1]!) }) {
                if let reason = blockingReason(of: declaration) {
                    skipped.append((removed[declaration]!, reason))
                    removed[declaration] = nil
                    isStable = false
                }
            }
        }

        for (declaration, candidate) in extensionCandidates where removedExtensions[declaration] == nil {
            skipped.append((candidate.target, .extendedTypeKept))
            extensionCandidates[declaration] = nil
        }
    }

    /// Keeps every case of a kept enum whose cases would all be removed: a `switch` over it would be left with only
    /// `default`. Returns whether a case was kept.
    private mutating func keepCasesOfEnumsLeftEmpty() -> Bool {
        let removedCases = removed.keys.filter { $0.kind == .enumelement }
        let enums = Set(removedCases.compactMap(\.parent)).filter { !isInRemovedDeclaration($0) }
        var changed = false

        for enumDecl in enums {
            let cases = enumDecl.declarations.filter { $0.kind == .enumelement }
            guard cases.allSatisfy({ removed[$0] != nil }) else { continue }

            for enumCase in cases.sorted(by: { Self.isOrdered(removed[$0]!, before: removed[$1]!) }) {
                skipped.append((removed[enumCase]!, .everyEnumCase))
                removed[enumCase] = nil
            }
            changed = true
        }
        return changed
    }

    private func blockingReason(of declaration: Declaration) -> SkipReason? {
        if drivesAssociatedTypeInference(declaration) {
            return .mayDriveAssociatedTypeInference
        }

        let scope = [declaration] + declaration.descendentDeclarations

        for member in scope {
            for extensionDecl in graph.extensions[member, default: []] where removedExtensions[extensionDecl] == nil {
                return .extensionKept
            }
        }

        for member in scope {
            for reference in graph.references(to: member) where !isRemoved(reference.parent) {
                if let parent = reference.parent, parent.isImplicit, parent.parent == member.parent {
                    // A synthesized member of the same type, such as the memberwise initializer, follows the removal.
                    continue
                }
                return .referencedByKeptCode
            }
        }

        // A member is related to the members that override it or implement it, and to those it implements.
        if !Self.typeKinds.contains(declaration.kind) {
            for reference in declaration.related {
                guard let related = graph.declaration(withUsr: reference.usr), isRemoved(related) else {
                    return declaration.parent?.kind == .protocol ? .requirementImplementedElsewhere : .relatedToKeptCode
                }
            }
        }
        return nil
    }

    /// Whether the declaration is a requirement, or the witness of a requirement, of a protocol that declares an
    /// associated type: the compiler may infer the associated type from it, so removing it can change or break the
    /// conformance.
    private func drivesAssociatedTypeInference(_ declaration: Declaration) -> Bool {
        guard !Self.typeKinds.contains(declaration.kind), declaration.kind != .associatedtype else { return false }

        let requirements = [declaration] + declaration.related.compactMap { graph.declaration(withUsr: $0.usr) }
        return requirements.contains { requirement in
            guard let owner = requirement.parent, owner.kind == .protocol else { return false }

            return owner.declarations.contains { $0.kind == .associatedtype }
        }
    }

    /// Whether the declaration is in the set, or inside a declaration that is.
    private func isInRemovedDeclaration(_ declaration: Declaration) -> Bool {
        var current: Declaration? = declaration
        while let decl = current {
            if removed[decl] != nil {
                return true
            }
            current = decl.parent
        }
        return false
    }

    /// Whether the declaration is in the set, or inside a declaration or an extension that is.
    private func isRemoved(_ declaration: Declaration?) -> Bool {
        var current = declaration
        while let decl = current {
            if removed[decl] != nil || removedExtensions[decl] != nil {
                return true
            }
            current = decl.parent
        }
        return false
    }

    private func ineligibility(of declaration: Declaration, _ eligibility: Eligibility) -> SkipReason? {
        guard Self.removableKinds.contains(declaration.kind) else { return .unremovableKind }

        let retentionRules = eligibility.retentionRules

        if let reason = Self.exclusion(of: declaration, retentionRules: retentionRules, includingOverride: true) {
            return reason
        }
        let descendants = declaration.descendentDeclarations.filter { !$0.isImplicit }
        // A member ignored by a comment command must survive.
        if descendants.contains(where: {
            Self.exclusion(of: $0, retentionRules: retentionRules, includingOverride: false) != nil
                || graph.commandIgnoredDeclarations[$0] != nil
        }) {
            return .containsExcludedDeclaration
        }
        if Self.isPublicAPI(declaration),
           !eligibility.includesPublic || eligibility.configuration.settings(for: declaration).retainsPublic
        {
            return .publicDeclaration
        }
        if eligibility.uncoveredNames.writtenName(of: declaration) != nil {
            return .uncoveredConditionalName
        }
        if eligibility.uncoveredNames.reachingType(of: declaration) != nil {
            return .uncoveredConditionalType
        }
        if eligibility.uncoveredNames.mayUseImplicitly(declaration) {
            return .implicitMemberWithUncoveredCode
        }

        if declaration.kind == .enumelement, let enumDecl = declaration.parent {
            if enumDecl.hasAttribute(named: "objc") {
                return .excludedAttribute("objc")
            }
            let conformances = conformanceNames(of: enumDecl)
            if conformances.contains("CaseIterable") {
                return .caseIterableEnumCase
            }
            if !conformances.isDisjoint(with: Self.codableProtocols) {
                return .codableEnumCase
            }
        }
        return nil
    }

    /// Whether the declaration is `public` or `open`, or is a case or a requirement of a public enum or protocol.
    private static func isPublicAPI(_ declaration: Declaration) -> Bool {
        let publicLevels: Set<Accessibility> = [.public, .open]
        if publicLevels.contains(declaration.accessibility.value) {
            return true
        }
        guard let parent = declaration.parent,
              declaration.kind == .enumelement || declaration.kind == .associatedtype || parent.kind == .protocol
        else { return false }

        return publicLevels.contains(parent.accessibility.value)
    }

    private static func exclusion(of declaration: Declaration, retentionRules: [AttributeRetentionRule], includingOverride: Bool) -> SkipReason? {
        for modifier in excludedModifiers where declaration.modifiers.contains(modifier) {
            if modifier != "override" || includingOverride {
                return .excludedModifier(modifier)
            }
        }
        if let attribute = excludedAttributes.first(where: { declaration.hasAttribute(named: $0) }) {
            return .excludedAttribute(attribute)
        }
        if declaration.isObjcAccessible {
            return .excludedAttribute("objc")
        }
        if retentionRules.contains(where: { $0.retains(declaration) }) {
            return .retainedAttribute
        }
        return nil
    }

    /// Why the declaration may not be removed if the syntax shows it is a stored property.
    private func storedPropertyRefusal(of declaration: Declaration, _ eligibility: Eligibility) -> SkipReason? {
        guard declaration.kind == .varInstance, let type = declaration.parent else { return nil }

        // Removing a stored property changes the layout of its type, which unsafe pointers, `withUnsafeBytes`,
        // padding or reserved fields and `@frozen` types depend on.
        if type.hasAttribute(named: "frozen") {
            return .frozenType
        }
        if !eligibility.includesStoredProperties {
            return .storedPropertyNotIncluded
        }

        if type.kind == .struct {
            let memberwiseInitializers = type.declarations.filter { $0.kind == .functionConstructor && $0.isImplicit }
            if memberwiseInitializers.contains(where: { graph.usedDeclarations.contains($0) || graph.hasReferences(to: $0) }) {
                return .memberwiseInitializerUsed
            }
        }
        if conformsToSynthesizingProtocol(type) {
            return .synthesizedConformance
        }
        return nil
    }

    /// Whether the type, its superclasses or the protocols it conforms to may include a protocol whose conformance is
    /// synthesized from the stored properties, such as Equatable, Hashable or Codable. A conformance through a
    /// typealias, a superclass outside the scan, and a protocol outside the scan that is not known to be safe count.
    private func conformsToSynthesizingProtocol(_ type: Declaration) -> Bool {
        var visited: Set<Declaration> = []
        var pending = [type]

        while let current = pending.popLast() {
            guard visited.insert(current).inserted else { continue }

            if current.references.contains(where: { $0.declarationKind == .typealias && $0.parent === current }) {
                return true
            }
            for reference in current.related where [.protocol, .class].contains(reference.declarationKind) {
                if let inherited = graph.declaration(withUsr: reference.usr) {
                    pending.append(inherited)
                } else if reference.declarationKind == .class || !Self.nonSynthesizingExternalProtocols.contains(reference.name) {
                    return true
                }
            }
        }
        return false
    }

    /// The names of the protocols the type conforms to, directly or through the protocols of the scan it conforms to.
    private func conformanceNames(of type: Declaration) -> Set<String> {
        var names: Set<String> = []
        var visited: Set<Declaration> = []
        var pending = [type]

        while let current = pending.popLast() {
            guard visited.insert(current).inserted else { continue }

            for reference in current.related where reference.declarationKind == .protocol {
                names.insert(reference.name)
                if let inherited = graph.declaration(withUsr: reference.usr) {
                    pending.append(inherited)
                }
            }
        }
        return names
    }

    private static func isOrdered(_ lhs: FixTarget, before rhs: FixTarget) -> Bool {
        (lhs.file.string, lhs.line, lhs.column, lhs.name) < (rhs.file.string, rhs.line, rhs.column, rhs.name)
    }
}

/// What makes an unused declaration ineligible beside its own syntax and references.
private struct Eligibility {
    let retentionRules: [AttributeRetentionRule]
    let configuration: Configuration
    let uncoveredNames: UncoveredConditionalNames
    let includesPublic: Bool
    let includesStoredProperties: Bool
}

public extension FixPlanner {
    /// Plans the removals with the other fixes. A removal the planner skips is kept, which can keep the declarations
    /// it needs, so the plan is made again until every remaining removal is applied.
    func plan(_ targets: [FixTarget], removing removal: inout UnusedRemovalSet) -> FixPlan {
        var plan = plan(targets + removal.targets)
        while true {
            let kept = plan.skipped.filter { $0.target.rule == .unused }.map { (target: $0.target, reason: $0.reason) }
            guard !kept.isEmpty, removal.keep(kept) else { break }

            plan = self.plan(targets + removal.targets)
        }
        let plannedSkips = Set(plan.skipped.map(\.target))
        plan.addSkipped(removal.skipped.filter { !plannedSkips.contains($0.target) })
        return plan
    }
}
