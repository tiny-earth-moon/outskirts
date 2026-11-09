/// Resolves, against the source graph, the receivers written in platform conditional clauses, to tell which
/// declarations a member written on them may be.
///
/// A receiver narrows a member only when what the clause writes proves its type: a project type named as a type
/// (`T.name`, `T(...).name`, `let value: T`), a type the clause declares (`self.name`, or a bare name in it), or an
/// external type (`ProcessInfo.processInfo.arguments.name`). Everything else (a value bound outside the clause or
/// without an initializer, a property, a type alias, a generic parameter) leaves the type unknown, and every
/// declaration of the name is retained.
final class PlatformConditionalReceiverResolver {
    enum ReceiverType {
        /// The declarations of project types: classes, structs, enums and protocols.
        case project(Set<Declaration>)
        /// An external type. `isRoot` when it is an identifier the project does not declare, which may be a module.
        case external(isRoot: Bool)
        case unknown
    }

    private static let typeKinds: Set<Declaration.Kind> = [.class, .struct, .enum, .protocol]
    /// The declarations a name written in an expression cannot refer to from another declaration.
    private static let unreachableKinds: Set<Declaration.Kind> = [.varParameter, .varLocal, .genericTypeParam, .module]

    private let graph: SourceGraph
    private let conformingExtendedNames: Set<String>
    private let clauseDeclaredTypeNames: Set<String>
    private let declarationsByName: [String: [Declaration]]
    /// The extensions of the project's protocols, which are not folded into them.
    private let protocolExtensions: [Declaration: [Declaration]]
    /// The members of the extensions of external types, by name.
    private let externalTypeExtensionMembers: [String: Set<Declaration>]
    /// The members of the project's protocols and of their extensions, by name.
    private let protocolMembers: [String: Set<Declaration>]
    private var closures: [Set<Declaration>: Closure] = [:]
    /// The types around the use being resolved.
    private var lexicalTypeNames: [String] = []

    /// The project types a receiver may be, those it inherits from and those that inherit from it, with whether one
    /// of them inherits from an external type.
    private struct Closure {
        let declarations: Set<Declaration>
        let hasExternalSuperclass: Bool
        let hasExternalSupertype: Bool
    }

    init(graph: SourceGraph) {
        self.graph = graph
        conformingExtendedNames = graph.platformConditionalConformingExtendedNames
        clauseDeclaredTypeNames = graph.platformConditionalDeclaredTypeNames
        declarationsByName = Dictionary(grouping: graph.allDeclarations.filter { !Self.unreachableKinds.contains($0.kind) }) {
            PlatformConditionalRetainer.baseName(of: $0.name)
        }
        // The extensions of project classes, structs and enums are folded into them: the extensions left are those
        // of external types and of the project's protocols.
        var protocolExtensions: [Declaration: [Declaration]] = [:]
        var externalTypeExtensionMembers: [String: Set<Declaration>] = [:]
        var protocolMembers: [String: Set<Declaration>] = [:]
        for extensionDecl in graph.declarations(ofKinds: Declaration.Kind.extensionKinds) {
            let extendedProtocol = extensionDecl.kind == .extensionProtocol
                ? extensionDecl.references
                .first { $0.declarationKind == .protocol && $0.name == extensionDecl.name }
                .flatMap { graph.declaration(withUsr: $0.usr) }
                : nil
            if let extendedProtocol {
                protocolExtensions[extendedProtocol, default: []].append(extensionDecl)
                Self.insert(extensionDecl.declarations, into: &protocolMembers)
            } else {
                Self.insert(extensionDecl.declarations, into: &externalTypeExtensionMembers)
            }
        }
        for protocolDecl in graph.declarations(ofKind: .protocol) {
            Self.insert(protocolDecl.declarations, into: &protocolMembers)
        }
        self.protocolExtensions = protocolExtensions
        self.externalTypeExtensionMembers = externalTypeExtensionMembers
        self.protocolMembers = protocolMembers
    }

    /// The declarations of the name the member use may be, or nil when it may be any.
    func candidates(for use: PlatformConditionalMemberUse) -> Set<Declaration>? {
        let result: Set<Declaration>
        lexicalTypeNames = use.lexicalTypeNames
        switch resolve(use.receiver, depth: 0) {
        case .unknown:
            return nil
        case let .project(types):
            let closure = closure(of: types)
            // The members and conformances of an external superclass, retroactive ones included, are unknown, and so
            // are the conformances an uncompiled clause adds.
            guard !closure.hasExternalSuperclass,
                  !types.contains(where: { conformingExtendedNames.contains(Self.baseName(of: $0)) })
            else { return nil }

            // A type may conform implicitly to an external protocol (`Hashable`, `Sendable`, `Actor`...), whose
            // extensions the project may declare.
            result = closure.declarations.flatMapSet { members(of: $0, named: use.name) }
                .union(externalTypeExtensionMembers[use.name, default: []])
        case .external:
            result = externalMembers(named: use.name)
        }

        // A bare name no type of the receiver declares is a free function, a global or a type.
        return use.isBare && result.isEmpty ? nil : result
    }

    // MARK: - Private

    private func resolve(_ receiver: PlatformConditionalReceiver, depth: Int) -> ReceiverType {
        guard depth < 16 else { return .unknown }

        switch receiver {
        case let .enclosingTypes(names):
            return resolveType(named: names, isRoot: false)
        case let .name(name):
            let declarations = declarationsByName[name, default: []]
            guard declarations.allSatisfy({ Self.typeKinds.contains($0.kind) || $0.kind.isExtensionKind }) else {
                return .unknown
            }

            return unshadowed(resolveType(named: [name], isRoot: true))
        case let .typeName(name):
            let declarations = declarationsByName[name, default: []]
            guard !declarations.contains(where: { [.typealias, .associatedtype].contains($0.kind) }) else { return .unknown }

            return unshadowed(resolveType(named: [name], isRoot: false))
        case let .inferred(value):
            // The value of a project type may be a subtype, or shadowed: only an external type is kept.
            if case .project = resolve(value, depth: depth + 1) {
                return .unknown
            }
            return resolve(value, depth: depth + 1)
        case let .member(base, name):
            return resolveMember(name, of: resolve(base, depth: depth + 1))
        case let .call(callee, hasOnlyLiteralArguments):
            switch resolve(callee, depth: depth + 1) {
            case let .project(types):
                // Only a type resolves to project types: calling it constructs it.
                return .project(types)
            case .external where hasOnlyLiteralArguments:
                return .external(isRoot: false)
            default:
                return .unknown
            }
        case .literal:
            return .external(isRoot: false)
        case .unknown:
            return .unknown
        }
    }

    /// The project types of these names, or an external type when the project only extends them or does not declare
    /// them. A type a platform conditional clause declares may be another one, with other supertypes.
    private func resolveType(named names: [String], isRoot: Bool) -> ReceiverType {
        guard names.allSatisfy({ !clauseDeclaredTypeNames.contains($0) }) else { return .unknown }

        let types = Set(names.flatMap { declarationsByName[$0, default: []] }.filter { Self.typeKinds.contains($0.kind) })
        return types.isEmpty ? .external(isRoot: isRoot) : .project(types)
    }

    private func resolveMember(_ name: String, of base: ReceiverType) -> ReceiverType {
        switch base {
        case let .project(types):
            let nestedTypes = closure(of: types).declarations
                .flatMapSet { members(of: $0, named: name) }
                .filter { Self.typeKinds.contains($0.kind) }
            return nestedTypes.isEmpty || clauseDeclaredTypeNames.contains(name) ? .unknown : .project(nestedTypes)
        case let .external(isRoot):
            guard !clauseDeclaredTypeNames.contains(name) else { return .unknown }

            let declarations = declarationsByName[name, default: []]
            if isRoot {
                // `Module.T`.
                let types = Set(declarations.filter { Self.typeKinds.contains($0.kind) })
                if !types.isEmpty {
                    return .project(types)
                }
            }
            return externalMembers(named: name).isEmpty ? .external(isRoot: false) : .unknown
        case .unknown:
            return .unknown
        }
    }

    /// The members of the name a value of an external type may have in the project: those of the extensions of
    /// external types, and those of protocols and their extensions, as an external type may conform to them.
    private func externalMembers(named name: String) -> Set<Declaration> {
        externalTypeExtensionMembers[name, default: []].union(protocolMembers[name, default: []])
    }

    /// The project types a type name resolves to, unless the name may refer, around the use, to something else: a
    /// member, a generic parameter or an associated type of an enclosing type, possibly inherited from an external
    /// type.
    private func unshadowed(_ type: ReceiverType) -> ReceiverType {
        guard case let .project(types) = type else { return type }

        let names = Set(types.map { Self.baseName(of: $0) })
        let isShadowable = lexicalTypeNames.contains { lexicalName in
            let lexicalTypes = Set(declarationsByName[lexicalName, default: []].filter { Self.typeKinds.contains($0.kind) })
            // An extension of an external type, whose generic parameters and associated types are unknown.
            guard !lexicalTypes.isEmpty else { return true }

            let closure = closure(of: lexicalTypes)
            return closure.hasExternalSupertype || closure.declarations.contains { type in
                names.contains { !members(of: type, named: $0).isEmpty }
            }
        }
        return isShadowable ? .unknown : type
    }

    private static func insert(_ declarations: Set<Declaration>, into membersByName: inout [String: Set<Declaration>]) {
        for member in declarations where !PlatformConditionalRetainer.nonReferenceableKinds.contains(member.kind) {
            membersByName[baseName(of: member), default: []].insert(member)
        }
    }

    private func closure(of types: Set<Declaration>) -> Closure {
        if let closure = closures[types] {
            return closure
        }

        var declarations = types
        var hasExternalSuperclass = false
        var hasExternalSupertype = false

        for type in types {
            for reference in graph.inheritedTypeReferences(of: type) {
                if let inherited = graph.declaration(withUsr: reference.usr) {
                    declarations.insert(inherited)
                } else {
                    hasExternalSupertype = true
                    hasExternalSuperclass = hasExternalSuperclass || reference.declarationKind == .class
                }
            }
        }
        declarations.formUnion(types.flatMapSet { subtypes(of: $0) })

        let closure = Closure(
            declarations: declarations,
            hasExternalSuperclass: hasExternalSuperclass,
            hasExternalSupertype: hasExternalSupertype
        )
        closures[types] = closure
        return closure
    }

    /// The classes that inherit from the type and the types that conform to it, transitively.
    private func subtypes(of type: Declaration) -> Set<Declaration> {
        var result: Set<Declaration> = []
        var pending = [type]

        while let current = pending.popLast() {
            for reference in graph.references(to: current) where reference.kind == .related {
                guard let subtype = reference.parent else { continue }

                if Self.typeKinds.contains(subtype.kind), result.insert(subtype).inserted {
                    pending.append(subtype)
                }
            }
        }

        return result
    }

    /// The members of the type, those of its extensions included, that bear the name.
    private func members(of type: Declaration, named name: String) -> Set<Declaration> {
        protocolExtensions[type, default: []]
            .reduce(into: type.declarations) { $0.formUnion($1.declarations) }
            .filter { !PlatformConditionalRetainer.nonReferenceableKinds.contains($0.kind) && Self.baseName(of: $0) == name }
    }

    private static func baseName(of declaration: Declaration) -> String {
        PlatformConditionalRetainer.baseName(of: declaration.name)
    }
}
