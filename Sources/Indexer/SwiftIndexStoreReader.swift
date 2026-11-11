import Configuration
import IndexStore
import SourceGraph

struct LocalizedStringCalleePosition: Hashable {
    let line: Int
    let column: Int
}

/// Reads the index store records of a source file's units into raw declarations and references, before any of
/// them reaches the graph.
struct SwiftIndexStoreReader {
    // swiftlint:disable nesting
    struct RawRelation {
        struct Symbol {
            let name: String
            let usr: String?
            let kind: SymbolKind
            let subKind: SymbolSubkind
        }

        let symbol: Symbol
        let roles: SymbolRoles
    }

    struct RawDeclaration {
        struct Key: Hashable {
            let kind: Declaration.Kind
            let name: String
            let isImplicit: Bool
            let isObjcAccessible: Bool
            let location: Location
        }

        let usr: String
        let kind: Declaration.Kind
        let name: String
        let isImplicit: Bool
        let isObjcAccessible: Bool
        let location: Location

        var key: Key {
            Key(kind: kind, name: name, isImplicit: isImplicit, isObjcAccessible: isObjcAccessible, location: location)
        }
    }

    // swiftlint:enable nesting

    /// The index facts that the syntax collectors of phase two match against their call sites.
    struct ReferenceSites {
        var calleeUsrsByPosition: [LocalizedStringCalleePosition: Set<String>] = [:]
        var metalFunctionDescriptorNameLocations: Set<Location> = []
    }

    struct Records {
        var rawDeclsByKey: [RawDeclaration.Key: [(RawDeclaration, [RawRelation])]] = [:]
        var references: Set<Reference> = []
        var referencesByUsr: [String: Set<Reference>] = [:]
        var danglingReferences: [Reference] = []
        var varParameterUsrs: Set<String> = []
        var extensionUsrMap: [String: String] = [:]
        var referenceSites = ReferenceSites()
    }

    let sourceFile: SourceFile
    let units: [IndexUnit]
    let configuration: Configuration

    func read() throws -> Records {
        var records = Records()
        let collectCalleeUsrs = !configuration.disableUnusedLocalizedStringAnalysis
        let collectMetalDescriptorNames = configuration.detectUnusedMetalFunctions

        for unit in units {
            for recordName in unit.unit.recordNames {
                let record = try RecordReader(indexStore: unit.store, recordName: recordName)

                record.forEach(occurrence: { occurrence in
                    let usr = occurrence.symbol.usr

                    if collectMetalDescriptorNames, occurrence.roles.contains(.reference),
                       Self.metalFunctionDescriptorNameUsrs.contains(usr),
                       let location = self.transformLocation(occurrence.location)
                    {
                        records.referenceSites.metalFunctionDescriptorNameLocations.insert(location)
                    }

                    guard Self.shouldProcessOccurrence(occurrence),
                          let location = self.transformLocation(occurrence.location)
                    else { return }

                    var relations: [RawRelation] = []
                    occurrence.forEach(relation: { relSymbol, relRoles in
                        relations.append(RawRelation(
                            symbol: .init(
                                name: relSymbol.name,
                                usr: relSymbol.usr,
                                kind: relSymbol.kind,
                                subKind: relSymbol.subkind
                            ),
                            roles: relRoles
                        ))
                    })

                    if !occurrence.roles.isDisjoint(with: [.definition, .declaration]) {
                        if let (decl, relations) = Self.parseRawDeclaration(
                            occurrence,
                            usr,
                            location,
                            relations,
                            into: &records
                        ) {
                            records.rawDeclsByKey[decl.key, default: []].append((decl, relations))
                        }
                    }

                    if collectCalleeUsrs, occurrence.roles.contains(.reference),
                       Self.calleeSymbolKinds.contains(occurrence.symbol.kind)
                    {
                        let position = LocalizedStringCalleePosition(line: location.line, column: location.column)
                        records.referenceSites.calleeUsrsByPosition[position, default: []].insert(usr)
                    }

                    if occurrence.roles.contains(.reference) {
                        let references = Self.parseReference(
                            occurrence,
                            usr,
                            location,
                            relations,
                            into: &records
                        )
                        records.references.formUnion(references)
                    }

                    if occurrence.roles.contains(.implicit) {
                        let references = Self.parseImplicit(
                            usr,
                            location,
                            relations,
                            into: &records
                        )
                        records.references.formUnion(references)
                    }
                })
            }
        }

        return records
    }

    static func shouldProcessOccurrence(_ occurrence: SymbolOccurrence) -> Bool {
        occurrence.symbol.language == .swift
    }

    static func transformDeclarationKind(_ kind: SymbolKind, _ subKind: SymbolSubkind) -> Declaration.Kind? {
        switch subKind {
        case .accessorGetter: return .functionAccessorGetter
        case .accessorSetter: return .functionAccessorSetter
        case .swiftAccessorDidSet: return .functionAccessorDidset
        case .swiftAccessorWillSet: return .functionAccessorWillset
        case .swiftAccessorMutableAddressor: return .functionAccessorMutableaddress
        case .swiftAccessorAddressor: return .functionAccessorAddress
        case .swiftAccessorRead: return .functionAccessorRead
        case .swiftAccessorModify: return .functionAccessorModify
        case .swiftAccessorInit: return .functionAccessorInit
        case .swiftSubscript: return .functionSubscript
        case .swiftInfixOperator: return .functionOperatorInfix
        case .swiftPrefixOperator: return .functionOperatorPrefix
        case .swiftPostfixOperator: return .functionOperatorPostfix
        case .swiftGenericParameter: return .genericTypeParam
        case .swiftAssociatedType: return .associatedtype
        case .swiftExtensionOfClass: return .extensionClass
        case .swiftExtensionOfStruct: return .extensionStruct
        case .swiftExtensionOfProtocol: return .extensionProtocol
        case .swiftExtensionOfEnum: return .extensionEnum
        default: break
        }

        switch kind {
        case .module: return .module
        case .enum: return .enum
        case .struct: return .struct
        case .class: return .class
        case .protocol: return .protocol
        case .extension: return .extension
        case .typealias: return .typealias
        case .function: return .functionFree
        case .variable: return .varGlobal
        case .enumConstant: return .enumelement
        case .instanceMethod: return .functionMethodInstance
        case .classMethod: return .functionMethodClass
        case .staticMethod: return .functionMethodStatic
        case .instanceProperty: return .varInstance
        case .classProperty: return .varClass
        case .staticProperty: return .varStatic
        case .constructor: return .functionConstructor
        case .destructor: return .functionDestructor
        case .parameter: return .varParameter
        case .macro: return .macro
        default: return nil
        }
    }

    // MARK: - Private

    /// The `name` property of `MTLFunctionDescriptor`, and its setter, which the index records at the same token.
    private static let metalFunctionDescriptorNameUsrs: Set<String> = [
        "c:objc(cs)MTLFunctionDescriptor(py)name",
        "c:objc(cs)MTLFunctionDescriptor(im)setName:",
    ]

    private static let calleeSymbolKinds: Set<SymbolKind> = [
        .function, .instanceMethod, .classMethod, .staticMethod, .constructor, .conversionFunction,
    ]

    private static func parseRawDeclaration(
        _ occurrence: SymbolOccurrence,
        _ usr: String,
        _ location: Location,
        _ relations: [RawRelation],
        into records: inout Records
    ) -> (RawDeclaration, [RawRelation])? {
        guard let kind = transformDeclarationKind(occurrence.symbol.kind, occurrence.symbol.subkind)
        else { return nil }
        guard kind != .varParameter else {
            // Ignore indexed parameters as unused parameter identification is performed separately using SwiftSyntax.
            // Record the USR so that we can also ignore implicit accessor declarations.
            records.varParameterUsrs.insert(usr)
            return nil
        }

        var usr = usr

        if kind.isExtensionKind {
            // Identical extensions in different modules have the same USR, which leads to conflicts and incorrect
            // results. Here we append the module names to form a unique USR. The only references to this
            // extension will exist in the same file, so we only need a file-local mapping for the USR.
            let newUsr = "\(usr)-\(location.file.modules.sorted().joined(separator: "-"))"
            records.extensionUsrMap[usr] = newUsr
            usr = newUsr
        }

        let decl = RawDeclaration(
            usr: usr,
            kind: kind,
            name: occurrence.symbol.name,
            isImplicit: occurrence.roles.contains(.implicit),
            isObjcAccessible: usr.hasPrefix("c:"),
            location: location
        )

        return (decl, relations)
    }

    private static func parseImplicit(
        _ occurrenceUsr: String,
        _ location: Location,
        _ relations: [RawRelation],
        into records: inout Records
    ) -> [Reference] {
        var refs = [Reference]()

        for relation in relations {
            if relation.roles.contains(.overrideOf) {
                let baseFunc = relation.symbol

                if let baseFuncUsr = baseFunc.usr, let baseFuncKind = transformDeclarationKind(baseFunc.kind, baseFunc.subKind) {
                    let reference = Reference(
                        name: baseFunc.name,
                        kind: .related,
                        declarationKind: baseFuncKind,
                        usr: baseFuncUsr,
                        location: location
                    )
                    records.referencesByUsr[occurrenceUsr, default: []].insert(reference)
                    refs.append(reference)
                }
            }
        }

        return refs
    }

    private static func parseReference(
        _ occurrence: SymbolOccurrence,
        _ occurrenceUsr: String,
        _ location: Location,
        _ relations: [RawRelation],
        into records: inout Records
    ) -> [Reference] {
        guard let kind = transformDeclarationKind(occurrence.symbol.kind, occurrence.symbol.subkind)
        else { return [] }
        guard kind != .varParameter else {
            // Ignore indexed parameters as unused parameter identification is performed separately using SwiftSyntax.
            return []
        }

        var refs = [Reference]()

        for relation in relations {
            if !relation.roles.isDisjoint(with: [.baseOf, .calledBy, .containedBy, .extendedBy]) {
                let referencer = relation.symbol

                if let referencerUsr = referencer.usr {
                    let ref = Reference(
                        name: occurrence.symbol.name,
                        kind: relation.roles.contains(.baseOf) ? .related : .normal,
                        declarationKind: kind,
                        usr: occurrenceUsr,
                        location: location
                    )
                    refs.append(ref)
                    records.referencesByUsr[referencerUsr, default: []].insert(ref)
                }
            }
        }

        if refs.isEmpty {
            let ref = Reference(
                name: occurrence.symbol.name,
                kind: .normal,
                declarationKind: kind,
                usr: occurrenceUsr,
                location: location
            )
            refs.append(ref)

            // The index store doesn't contain any relations for this reference, save it so that we can attempt
            // to associate it with the correct declaration later based on location.
            if ref.declarationKind != .module {
                records.danglingReferences.append(ref)
            }
        }

        return refs
    }

    private func transformLocation(_ input: (line: Int, column: Int)) -> Location? {
        Location(file: sourceFile, line: input.line, column: input.column)
    }
}
