import Configuration
import Foundation
import Shared

/// The index store only describes the platform it was built for, so code that is only reachable on another
/// platform appears unused. This retains:
///  - declarations marked `@available(<platform>, unavailable)`, as they exist for other platforms,
///  - the members written, in a platform conditional clause no indexed build compiles with certainty, on a receiver
///    whose type the clause proves, in the types the receiver may be, and the operator members of a type such a clause
///    names alongside the operator,
///  - the members such a clause uses without writing their name: the initializers it calls (`T(...)`, `.init(...)`
///    typed `T`, `T.self`) whose labels match, exactly when one does, the subscripts of a type it names when it
///    accesses a value with `[ ]`, the `callAsFunction` of a type it names when it calls a value, and the witnesses of
///    a conformance one of its extensions declares,
///  - with `platform_conditional_retention: names` only, every declaration of a name written bare, or on a receiver
///    whose type is unknown, inside a platform conditional `#if` block no indexed build compiled, as the reference may
///    live in a branch that was not compiled: a local variable, a free function or a C call of the same name retain
///    every same-named member of the project, which is why it is opt-in.
///
/// With `platform_conditional_retention: auto`, a declaration marked unavailable is not retained when its file was
/// indexed for one of these platforms and for a platform where it is available (see `IndexVariant.cover`), by units
/// written since the file was last modified: an older unit misses the uses added since.
final class PlatformConditionalRetainer: SourceGraphMutator {
    static let nonReferenceableKinds: Set<Declaration.Kind> = [
        .module, .extension, .extensionClass, .extensionEnum, .extensionProtocol, .extensionStruct,
        .functionConstructor, .functionDestructor, .varParameter, .varLocal, .genericTypeParam,
        .functionAccessorAddress, .functionAccessorDidset, .functionAccessorGetter, .functionAccessorMutableaddress,
        .functionAccessorSetter, .functionAccessorWillset, .functionAccessorRead, .functionAccessorModify,
        .functionAccessorInit,
    ]

    private static let typeKinds: Set<Declaration.Kind> = [.class, .struct, .enum]
    private static let namedTypeKinds: Set<Declaration.Kind> = typeKinds.union([.protocol, .typealias])
    private static let operatorKinds: Set<Declaration.Kind> = [
        .functionOperator, .functionOperatorInfix, .functionOperatorPrefix, .functionOperatorPostfix,
    ]
    /// The declarations whose operator members are retained when named alongside them.
    private static let operatorDeclaringKinds: Set<Declaration.Kind> = typeKinds.union([
        .protocol, .extensionClass, .extensionEnum, .extensionProtocol, .extensionStruct,
    ])

    /// An initializer can implement an `init` requirement.
    private static let nonWitnessKinds = nonReferenceableKinds.subtracting([.functionConstructor])

    private let graph: SourceGraph
    private let configuration: Configuration
    private lazy var resolver = PlatformConditionalReceiverResolver(graph: graph)

    required init(graph: SourceGraph, configuration: Configuration, swiftVersion _: SwiftVersion) {
        self.graph = graph
        self.configuration = configuration
    }

    func mutate() {
        let retention = configuration.resolvedPlatformConditionalRetention
        guard retention != .off else { return }

        let names = retention.retainsNames ? graph.platformConditionalUnscopedNames : []

        for decl in graph.allDeclarations {
            let unavailablePlatforms = Self.unavailablePlatforms(of: decl)
            let isCovered = retention == .auto
                && IndexVariant.cover(unavailablePlatforms: unavailablePlatforms, in: decl.location.file.currentVariants)

            if !unavailablePlatforms.isEmpty, !isCovered {
                graph.markRetained(decl, reason: RetentionReason(Self.self, "declared unavailable on a platform with @available"))
                graph.markRetained(decl.descendentDeclarations, reason: RetentionReason(Self.self, "inside \(decl.name), declared unavailable on a platform with @available"))
            } else if !names.isEmpty,
                      !Self.nonReferenceableKinds.contains(decl.kind),
                      names.contains(Self.baseName(of: decl.name)),
                      isOperatorNamedWithItsType(decl)
            {
                graph.markRetained(decl, reason: operatorTypeName(of: decl).map { typeName in
                    RetentionReason(Self.self, "operator '\(Self.baseName(of: decl.name))' applied in a platform conditional clause that names '\(typeName)' and no indexed build compiles with certainty")
                } ?? nameRetentionReason(Self.baseName(of: decl.name)))
            }
        }

        if retention.retainsNames {
            retainScopedMembers(graph.platformConditionalMemberUses.filter { !names.contains($0.name) }, retainingUnresolved: true)
        } else {
            retainUncompiledOperatorMembers()
            retainUncompiledTypes()
            retainScopedMembers(graph.platformConditionalUncompiledMemberUses, retainingUnresolved: false)
            recordNameOnlyDeclarations()
        }
        retainUnnamedMembers()
        retainConformanceWitnesses()
    }

    // MARK: - Private

    /// Whether the declaration is not an operator member, or its type is named in a clause that applies it: `*` written
    /// alone does not use the `*` of every type.
    private func isOperatorNamedWithItsType(_ decl: Declaration) -> Bool {
        guard let typeName = operatorTypeName(of: decl) else { return true }

        let clauseNames = graph.platformConditionalOperatorClauseNames[Self.baseName(of: decl.name), default: []]
        return clauseNames.contains(typeName)
    }

    /// The name of the type, extension or protocol that declares the operator, or nil for a free operator or another
    /// declaration.
    private func operatorTypeName(of decl: Declaration) -> String? {
        guard Self.operatorKinds.contains(decl.kind),
              let parent = decl.parent,
              Self.operatorDeclaringKinds.contains(parent.kind)
        else { return nil }

        return Self.baseName(of: parent.name)
    }

    /// The members written on a receiver, or bare in a type the clause declares: only the declarations of the types the
    /// receiver may be, and, with `retainingUnresolved`, every declaration of the name when its type is unknown (see
    /// `PlatformConditionalReceiverResolver`).
    private func retainScopedMembers(
        _ uses: Set<PlatformConditionalMemberUse>,
        retainingUnresolved: Bool
    ) {
        guard !uses.isEmpty else { return }

        let (unresolvedNames, candidatesByName) = resolve(uses, boundingOpenTypes: !retainingUnresolved)
        let retainedNames = retainingUnresolved ? unresolvedNames : []

        if !retainedNames.isEmpty {
            for decl in graph.allDeclarations where !Self.nonReferenceableKinds.contains(decl.kind) {
                let name = Self.baseName(of: decl.name)
                if retainedNames.contains(name) {
                    graph.markRetained(decl, reason: nameRetentionReason(name))
                }
            }
        }
        for (name, candidates) in candidatesByName where !retainedNames.contains(name) {
            for decl in candidates {
                graph.markRetained(decl, reason: nameRetentionReason(name))
            }
        }
    }

    /// The names of the uses whose receiver's type is unknown, and the declarations each other name may be.
    private func resolve(_ uses: Set<PlatformConditionalMemberUse>, boundingOpenTypes: Bool) -> (unresolvedNames: Set<String>, candidatesByName: [String: Set<Declaration>]) {
        var unresolvedNames: Set<String> = []
        var candidatesByName: [String: Set<Declaration>] = [:]

        for use in uses where !unresolvedNames.contains(use.name) {
            if let candidates = resolver.candidates(for: use, boundingOpenTypes: boundingOpenTypes) {
                candidatesByName[use.name, default: []].formUnion(candidates)
            } else {
                unresolvedNames.insert(use.name)
            }
        }

        return (unresolvedNames, candidatesByName)
    }

    /// The classes, structs, enums, protocols and type aliases named in a clause no indexed build compiles: a type
    /// name, unlike a member name, does not depend on a receiver.
    private func retainUncompiledTypes() {
        let names = graph.platformConditionalUncompiledReferences
        guard !names.isEmpty else { return }

        for decl in graph.declarations(ofKinds: Self.namedTypeKinds) {
            let name = Self.baseName(of: decl.name)
            if names.contains(name) {
                graph.markRetained(decl, reason: nameRetentionReason(name))
            }
        }
    }

    /// The operator members of a type named in a clause no indexed build compiles that applies the operator.
    private func retainUncompiledOperatorMembers() {
        let clauseNamesByOperator = graph.platformConditionalUncompiledOperatorClauseNames
        guard !clauseNamesByOperator.isEmpty else { return }

        for decl in graph.declarations(ofKinds: Self.operatorKinds) {
            let name = Self.baseName(of: decl.name)
            guard let typeName = operatorTypeName(of: decl),
                  clauseNamesByOperator[name, default: []].contains(typeName)
            else { continue }

            graph.markRetained(decl, reason: RetentionReason(Self.self, "operator '\(name)' applied in a platform conditional clause that names '\(typeName)' and no indexed build compiles with certainty"))
        }
    }

    /// The declarations `names` would retain by name that are not retained here: those of the names written bare or on
    /// a receiver of unknown type, operators of a type left out as their retention does not depend on it.
    private func recordNameOnlyDeclarations() {
        let unscopedNames = graph.platformConditionalUnscopedNames
        let uses = graph.platformConditionalMemberUses.filter { !unscopedNames.contains($0.name) }
        let names = unscopedNames.union(resolve(uses, boundingOpenTypes: false).unresolvedNames)
        guard !names.isEmpty else { return }

        let declarations = graph.allDeclarations.filter { decl in
            !Self.nonReferenceableKinds.contains(decl.kind)
                && operatorTypeName(of: decl) == nil
                && names.contains(Self.baseName(of: decl.name))
                && !graph.isRetained(decl)
        }
        graph.setPlatformConditionalNameOnlyDeclarations(declarations)
    }

    /// The members that a clause no indexed build compiles calls without writing their name: the initializers of its
    /// `T(...)`, `.init(...)` typed `T` and `T.self`, and the subscripts and `callAsFunction` of a type it names when it
    /// accesses a value with `[ ]` or calls a value.
    private func retainUnnamedMembers() {
        let constructionsByType = Dictionary(grouping: graph.platformConditionalConstructions, by: \.typeName)
        let subscriptedNames = graph.platformConditionalSubscriptedNames
        let valueCalledNames = graph.platformConditionalValueCalledNames
        guard !constructionsByType.isEmpty || !subscriptedNames.isEmpty || !valueCalledNames.isEmpty else { return }

        for type in graph.declarations(ofKinds: Self.typeKinds) {
            let typeName = Self.baseName(of: type.name)
            let constructions = constructionsByType[typeName, default: []]
            let isSubscripted = subscriptedNames.contains(typeName)
            let isValueCalled = valueCalledNames.contains(typeName)
            guard !constructions.isEmpty || isSubscripted || isValueCalled else { continue }

            let typeMembers = members(of: type)
            let calls = calledInitializers(in: typeMembers, by: constructions)

            for member in typeMembers {
                let reason: String? = switch member.kind {
                case .functionConstructor where calls[member] != nil:
                    calls[member].map { constructionRetentionReason($0, typeName: typeName) }
                case .functionSubscript where isSubscripted:
                    "subscript of '\(typeName)', named in a platform conditional clause no indexed build compiles that accesses a value with [ ]"
                case _ where isValueCalled && Self.baseName(of: member.name) == "callAsFunction":
                    "callAsFunction of '\(typeName)', named in a platform conditional clause no indexed build compiles that calls a value"
                default:
                    nil
                }
                if let reason {
                    graph.markRetained(member, reason: RetentionReason(Self.self, reason))
                }
            }
        }
    }

    /// The initializers each call may reach, with the call: those whose labels it writes exactly, or, when there is
    /// none, those whose other parameters may have default values.
    private func calledInitializers(
        in members: Set<Declaration>,
        by constructions: [PlatformConditionalConstruction]
    ) -> [Declaration: PlatformConditionalConstruction] {
        let initializers = members.filter { $0.kind == .functionConstructor }
        var result: [Declaration: PlatformConditionalConstruction] = [:]

        for construction in constructions {
            let exactMatches = initializers.filter { construction.matchesExactly(initializerName: $0.name) }
            let matches = exactMatches.isEmpty
                ? initializers.filter { construction.matches(initializerName: $0.name) }
                : exactMatches
            for initializer in matches where result[initializer] == nil {
                result[initializer] = construction
            }
        }

        return result
    }

    /// The first place, in file and line order, where the clause calls the initializer.
    private func constructionRetentionReason(_ construction: PlatformConditionalConstruction, typeName: String) -> String {
        let site = graph.platformConditionalConstructionSites[construction, default: []].min {
            ($0.file.path.string, $0.line) < ($1.file.path.string, $1.line)
        }
        guard let site else {
            return "initializer of '\(typeName)', called without its name in a platform conditional clause no indexed build compiles"
        }

        return "initializer of '\(typeName)', called without its name in \(site.condition) at \(site.file.path.string):\(site.line), a clause no indexed build compiles"
    }

    /// The members of a type that bear the name of a requirement of a protocol it conforms to in an extension written
    /// in a platform conditional block: they are its witnesses there.
    private func retainConformanceWitnesses() {
        let conformances = graph.platformConditionalConformances
        guard !conformances.isEmpty else { return }

        let protocolsByName = Dictionary(grouping: graph.declarations(ofKind: .protocol), by: \.name)
        let typesByName = Dictionary(grouping: graph.declarations(ofKinds: Self.typeKinds), by: \.name)

        for conformance in conformances {
            let requirementNames = protocolsByName[conformance.protocolName, default: []].flatMapSet { protocolDecl in
                Set(protocolDecl.declarations.map { Self.baseName(of: $0.name) })
            }
            guard !requirementNames.isEmpty else { continue }

            for type in typesByName[conformance.typeName, default: []] {
                for member in members(of: type) where !Self.nonWitnessKinds.contains(member.kind)
                    && requirementNames.contains(Self.baseName(of: member.name))
                {
                    graph.markRetained(member, reason: RetentionReason(Self.self, "witness of the conformance of '\(conformance.typeName)' to '\(conformance.protocolName)' declared in a platform conditional clause no indexed build compiles"))
                }
            }
        }
    }

    /// The members of the type, those of its extensions included.
    private func members(of type: Declaration) -> Set<Declaration> {
        graph.extensions[type, default: []].reduce(into: type.declarations) { $0.formUnion($1.declarations) }
    }

    /// The first place, in file and line order, where the name is written in a platform conditional block.
    private func nameRetentionReason(_ name: String) -> RetentionReason {
        let site = graph.platformConditionalNameSites[name, default: []].min {
            ($0.file.path.string, $0.line) < ($1.file.path.string, $1.line)
        }
        guard let site else {
            return RetentionReason(Self.self, "name '\(name)' written in a platform conditional block")
        }

        return RetentionReason(Self.self, "name '\(name)' written in \(site.condition) at \(site.file.path.string):\(site.line)")
    }

    static func baseName(of declarationName: String) -> String {
        declarationName.prefix { $0 != "(" }.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
    }

    private static func removingStringLiterals(from arguments: String) -> String {
        var result = ""
        var isInsideString = false
        var isEscaped = false

        for character in arguments {
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else if character == "\"" {
                isInsideString = true
            } else {
                result.append(character)
            }
        }

        return result
    }

    /// The platforms of the `@available(<platform>, unavailable)` attributes of the declaration.
    static func unavailablePlatforms(of decl: Declaration) -> Set<String> {
        decl.attributes.compactMapSet { attribute -> String? in
            guard attribute.name == "available", let arguments = attribute.arguments else { return nil }

            let parts = Self.removingStringLiterals(from: arguments)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            guard let platform = parts.first,
                  platform != "*",
                  platform != "swift",
                  !platform.hasSuffix("ApplicationExtension")
            else { return nil }

            return parts.dropFirst().contains("unavailable") ? platform : nil
        }
    }
}
