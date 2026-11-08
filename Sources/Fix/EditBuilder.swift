import Foundation
import SourceGraph
import SwiftSyntax

/// Builds the byte-range edits that fix one result, after re-locating its syntax node.
struct EditBuilder {
    let source: ParsedSource

    /// - Parameter ignoredParameterNames: for a superfluous `ignore:parameters` comment, the names of every parameter
    ///   of the same function whose ignore is reported as superfluous.
    func edits(for target: FixTarget, ignoredParameterNames: Set<String> = []) -> Result<[SourceEdit], SkipReason> {
        guard let token = source.token(atLine: target.line, column: target.column) else {
            return .failure(.locationMismatch)
        }

        switch target.rule {
        case .redundantPublic:
            return modifierEdits(token: token, target: target, keyword: "public", replacement: nil)
        case .redundantOpen:
            return modifierEdits(token: token, target: target, keyword: "open", replacement: "public")
        case .redundantAccessLevel:
            guard let accessibility = target.accessibility else { return .failure(.modifierNotFound) }

            return modifierEdits(token: token, target: target, keyword: accessibility.rawValue, replacement: nil)
        case .emptyExtension:
            return emptyExtensionEdits(token: token, target: target)
        case .unusedImport:
            return importEdits(token: token, target: target)
        case .superfluousIgnore:
            return superfluousIgnoreEdits(token: token, target: target, ignoredParameterNames: ignoredParameterNames)
        case .unusedParameter:
            return parameterEdits(token: token, target: target)
        case .missingFinal:
            return finalEdits(token: token, target: target)
        case .unused:
            return unusedDeclarationEdits(token: token, target: target)
        }
    }

    // MARK: - Private

    /// Deletes the modifier and the spaces that follow it, or replaces its keyword.
    private func modifierEdits(token: TokenSyntax, target: FixTarget, keyword: String, replacement: String?) -> Result<[SourceEdit], SkipReason> {
        guard let decl = DeclarationLocator.declaration(named: token, name: target.name, kind: target.kind) else {
            return .failure(.locationMismatch)
        }

        if let variable = decl.as(VariableDeclSyntax.self), variable.bindings.count > 1 {
            return .failure(.multipleBindings)
        }
        guard let modifiers = decl.asProtocol(WithModifiersSyntax.self)?.modifiers,
              let modifier = modifiers.first(where: { $0.name.text == keyword && $0.detail == nil })
        else { return .failure(.modifierNotFound) }

        let start = modifier.name.positionAfterSkippingLeadingTrivia.utf8Offset
        let end = modifier.name.endPositionBeforeTrailingTrivia.utf8Offset

        if let replacement {
            return .success([SourceEdit(range: start ..< end, replacement: replacement)])
        }

        var upperBound = end
        while upperBound < source.bytes.count, source.bytes[upperBound] == UInt8(ascii: " ") || source.bytes[upperBound] == UInt8(ascii: "\t") {
            upperBound += 1
        }
        return .success([SourceEdit(range: start ..< upperBound)])
    }

    /// Inserts `final` after the attributes and the access modifier: `@MainActor public class` becomes
    /// `@MainActor public final class`, and `class` becomes `final class`.
    private func finalEdits(token: TokenSyntax, target: FixTarget) -> Result<[SourceEdit], SkipReason> {
        guard let decl = DeclarationLocator.declaration(named: token, name: target.name, kind: target.kind),
              let classDecl = decl.as(ClassDeclSyntax.self)
        else { return .failure(.locationMismatch) }

        let modifiers = Array(classDecl.modifiers)
        if modifiers.contains(where: { $0.name.tokenKind == .keyword(.final) }) {
            return .failure(.alreadyFinal)
        }
        if modifiers.contains(where: { $0.name.tokenKind == .keyword(.open) }) {
            return .failure(.openClass)
        }

        let accessIndex = modifiers.lastIndex { Self.accessKeywords.contains($0.name.tokenKind) }
        let followingIndex = accessIndex.map { $0 + 1 } ?? 0
        let insertionToken = followingIndex < modifiers.count ? modifiers[followingIndex].name : classDecl.classKeyword
        let offset = insertionToken.positionAfterSkippingLeadingTrivia.utf8Offset
        return .success([SourceEdit(range: offset ..< offset, replacement: "final ")])
    }

    private static let accessKeywords: Set<TokenKind> = [
        .keyword(.public), .keyword(.package), .keyword(.internal), .keyword(.fileprivate), .keyword(.private),
    ]

    private func emptyExtensionEdits(token: TokenSyntax, target: FixTarget) -> Result<[SourceEdit], SkipReason> {
        guard let decl = DeclarationLocator.declaration(named: token, name: target.name, kind: target.kind),
              let extensionDecl = decl.as(ExtensionDeclSyntax.self)
        else { return .failure(.locationMismatch) }
        guard extensionDecl.inheritanceClause == nil, isEmpty(extensionDecl.memberBlock.members) else {
            return .failure(.extensionNotEmpty)
        }

        return .success([SourceEdit(range: source.statementRemovalRange(statement(of: extensionDecl)))])
    }

    /// Removes the declaration with its doc comment, its attributes and one trailing newline. An extension is only a
    /// target when the type it extends is removed, so it goes whatever it holds.
    private func unusedDeclarationEdits(token: TokenSyntax, target: FixTarget) -> Result<[SourceEdit], SkipReason> {
        guard let decl = DeclarationLocator.declaration(named: token, name: target.name, kind: target.kind) else {
            return .failure(.locationMismatch)
        }

        if let variable = decl.as(VariableDeclSyntax.self) {
            if let reason = storedPropertyRefusal(variable, target: target) {
                return .failure(reason)
            }
        } else if let enumCase = decl.as(EnumCaseDeclSyntax.self) {
            guard enumCase.elements.count == 1 else { return .failure(.severalCases) }

            if shiftsImplicitRawValues(enumCase) {
                return .failure(.implicitRawValues)
            }
        }
        return .success([SourceEdit(range: source.statementRemovalRange(statement(of: decl)))])
    }

    /// Why a variable may not be removed: a stored property must have no attribute (a property wrapper or a macro
    /// among them), no initializer or a literal one, and no initializer if it is static.
    private func storedPropertyRefusal(_ variable: VariableDeclSyntax, target: FixTarget) -> SkipReason? {
        guard variable.bindings.count == 1, let binding = variable.bindings.first else { return .multipleBindings }
        guard !isComputed(binding, of: variable) else { return nil }

        if let reason = target.storedPropertyRefusal {
            return reason
        }
        if !variable.attributes.isEmpty {
            return .attributedStoredProperty
        }
        guard let initializer = binding.initializer else { return nil }

        if variable.modifiers.contains(where: { [.keyword(.static), .keyword(.class)].contains($0.name.tokenKind) }) {
            return .staticInitializer
        }
        return isLiteral(initializer.value) ? nil : .nonLiteralInitializer
    }

    /// A protocol requirement, or a binding with a getter, has no storage; observers alone do not make it computed.
    private func isComputed(_ binding: PatternBindingSyntax, of variable: VariableDeclSyntax) -> Bool {
        let declGroup = variable.parent?.ancestorOrSelf { $0.isProtocol(DeclGroupSyntax.self) ? $0 : nil }
        if declGroup?.is(ProtocolDeclSyntax.self) == true {
            return true
        }
        switch binding.accessorBlock?.accessors {
        case .none:
            return false
        case .getter:
            return true
        case let .accessors(accessors):
            return accessors.contains { ![.keyword(.willSet), .keyword(.didSet)].contains($0.accessorSpecifier.tokenKind) }
        }
    }

    private func isLiteral(_ expression: ExprSyntax) -> Bool {
        if expression.is(IntegerLiteralExprSyntax.self) || expression.is(FloatLiteralExprSyntax.self)
            || expression.is(BooleanLiteralExprSyntax.self) || expression.is(NilLiteralExprSyntax.self)
        {
            return true
        }
        if let string = expression.as(StringLiteralExprSyntax.self) {
            return string.segments.allSatisfy { $0.is(StringSegmentSyntax.self) }
        }
        if let prefix = expression.as(PrefixOperatorExprSyntax.self) {
            return prefix.operator.text == "-"
                && (prefix.expression.is(IntegerLiteralExprSyntax.self) || prefix.expression.is(FloatLiteralExprSyntax.self))
        }
        if let array = expression.as(ArrayExprSyntax.self) {
            return array.elements.allSatisfy { isLiteral($0.expression) }
        }
        if let dictionary = expression.as(DictionaryExprSyntax.self) {
            guard case let .elements(elements) = dictionary.content else { return true }

            return elements.allSatisfy { isLiteral($0.key) && isLiteral($0.value) }
        }
        return false
    }

    /// Whether removing the case changes the raw value of a later case: a later case has no explicit raw value, in an
    /// enum whose raw values count up, that is with a numeric raw type or with any explicit raw value.
    private func shiftsImplicitRawValues(_ enumCase: EnumCaseDeclSyntax) -> Bool {
        guard let enumDecl = enumCase.ancestorOrSelf(mapping: { $0.as(EnumDeclSyntax.self) }),
              let removed = enumCase.elements.first
        else { return true }

        // The cases in source order, `#if` clauses included, without those of nested enums.
        let ordered = enumDecl.memberBlock.tokens(viewMode: .sourceAccurate)
            .compactMap { token in token.parent?.as(EnumCaseElementSyntax.self).flatMap { $0.name.id == token.id ? $0 : nil } }
            .filter { $0.ancestorOrSelf(mapping: { $0.as(EnumDeclSyntax.self) })?.id == enumDecl.id }
        guard let index = ordered.firstIndex(where: { $0.id == removed.id }) else { return true }

        let laterImplicit = ordered[(index + 1)...].contains { $0.rawValue == nil }
        guard laterImplicit else { return false }

        let rawType = enumDecl.inheritanceClause?.inheritedTypes.first?.type.trimmedDescription ?? ""
        let numericTypes: Set = [
            "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
            "Float", "Double", "Float80", "CGFloat",
        ]
        let isNumeric = numericTypes.contains(rawType.replacingOccurrences(of: "Swift.", with: ""))
        return isNumeric || ordered.contains { $0.rawValue != nil }
    }

    private func importEdits(token: TokenSyntax, target: FixTarget) -> Result<[SourceEdit], SkipReason> {
        guard target.kind == .module,
              let importDecl = token.ancestorOrSelf(mapping: { $0.as(ImportDeclSyntax.self) }),
              importDecl.positionAfterSkippingLeadingTrivia == token.positionAfterSkippingLeadingTrivia,
              importDecl.path.first?.name.text.trimmingBackticks == target.name
        else { return .failure(.locationMismatch) }

        let attributeNames = importDecl.attributes.compactMap { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription }
        if attributeNames.contains("_exported") || importDecl.modifiers.contains(where: { $0.name.text == "public" }) {
            return .failure(.exportedImport)
        }
        if attributeNames.contains("testable") {
            return .failure(.testableImport)
        }
        if importDecl.ancestorOrSelf(mapping: { $0.as(IfConfigClauseSyntax.self) }) != nil {
            return .failure(.conditionalImport)
        }

        return .success([SourceEdit(range: source.statementRemovalRange(statement(of: importDecl)))])
    }

    private func superfluousIgnoreEdits(token: TokenSyntax, target: FixTarget, ignoredParameterNames: Set<String>) -> Result<[SourceEdit], SkipReason> {
        let isParameter = target.kind == .varParameter
        let decl: DeclSyntax? = if isParameter {
            token.ancestorOrSelf(mapping: { $0.as(DeclSyntax.self) }).flatMap { decl in
                [.functionDecl, .initializerDecl, .subscriptDecl, .macroDecl].contains(decl.kind) ? decl : nil
            }
        } else {
            DeclarationLocator.declaration(named: token, name: target.name, kind: target.kind)
        }
        guard let decl else { return .failure(.locationMismatch) }

        var edits: [SourceEdit] = []
        for comment in commandComments(of: decl) {
            guard let command = IgnoreCommand(comment: comment.piece) else { continue }

            switch command {
            case .declaration where !isParameter:
                edits.append(SourceEdit(range: source.removalRange(from: comment.range.lowerBound, to: comment.range.upperBound)))
            case let .parameters(names) where isParameter && names.contains(target.name):
                guard Set(names).isSubset(of: ignoredParameterNames) else { return .failure(.partialParameterIgnore) }

                edits.append(SourceEdit(range: source.removalRange(from: comment.range.lowerBound, to: comment.range.upperBound)))
            default:
                continue
            }
        }
        return edits.isEmpty ? .failure(.ignoreCommentNotFound) : .success(edits)
    }

    /// Renames the internal name to `_` and keeps the argument label: `a: Int` becomes `a _: Int` and `_ a: Int`
    /// becomes `_: Int`. A subscript or operator parameter has no argument label, so `a: Int` becomes `_: Int`.
    private func parameterEdits(token: TokenSyntax, target: FixTarget) -> Result<[SourceEdit], SkipReason> {
        guard target.kind == .varParameter,
              token.text.trimmingBackticks == target.name,
              let parameter = token.parent?.as(FunctionParameterSyntax.self),
              parameter.secondName?.id == token.id || (parameter.secondName == nil && parameter.firstName.id == token.id)
        else { return .failure(.locationMismatch) }

        let firstName = parameter.firstName
        if let secondName = parameter.secondName {
            if firstName.tokenKind == .wildcard {
                let range = firstName.endPositionBeforeTrailingTrivia.utf8Offset ..< secondName.endPositionBeforeTrailingTrivia.utf8Offset
                return .success([SourceEdit(range: range)])
            }
            return .success([SourceEdit(range: range(of: secondName), replacement: "_")])
        }

        if hasArgumentLabels(parameter) {
            let end = firstName.endPositionBeforeTrailingTrivia.utf8Offset
            return .success([SourceEdit(range: end ..< end, replacement: " _")])
        }
        return .success([SourceEdit(range: range(of: firstName), replacement: "_")])
    }

    private func hasArgumentLabels(_ parameter: FunctionParameterSyntax) -> Bool {
        guard let decl = parameter.ancestorOrSelf(mapping: { $0.as(DeclSyntax.self) }) else { return false }

        if let function = decl.as(FunctionDeclSyntax.self) {
            switch function.name.tokenKind {
            case .binaryOperator, .prefixOperator, .postfixOperator: return false
            default: return true
            }
        }
        return decl.kind != .subscriptDecl
    }

    private func range(of token: TokenSyntax) -> Range<Int> {
        token.positionAfterSkippingLeadingTrivia.utf8Offset ..< token.endPositionBeforeTrailingTrivia.utf8Offset
    }

    /// The statement that holds the declaration, so that its removal takes a separating semicolon along.
    private func statement(of decl: some DeclSyntaxProtocol) -> Syntax {
        if let item = decl.parent?.as(CodeBlockItemSyntax.self) {
            return Syntax(item)
        }
        if let member = decl.parent?.as(MemberBlockItemSyntax.self) {
            return Syntax(member)
        }
        return Syntax(decl)
    }

    /// Members are empty when the only declarations are `#if` blocks whose clauses are all empty.
    private func isEmpty(_ members: MemberBlockItemListSyntax) -> Bool {
        members.allSatisfy { member in
            guard let ifConfig = member.decl.as(IfConfigDeclSyntax.self) else { return false }

            return ifConfig.clauses.allSatisfy { clause in
                switch clause.elements {
                case .none: true
                case let .decls(decls): isEmpty(decls)
                default: false
                }
            }
        }
    }

    /// The comments where a declaration's comment commands can be written: before it, after it on its last line,
    /// and after the braces of its body.
    private func commandComments(of decl: DeclSyntax) -> [OffsetTriviaPiece] {
        var tokens: [TokenSyntax] = []
        if let first = decl.firstToken(viewMode: .sourceAccurate) {
            tokens.append(first)
        }

        var trailingTokens: [TokenSyntax] = []
        if let last = decl.lastToken(viewMode: .sourceAccurate) {
            trailingTokens.append(last)
        }
        if let memberBlock = decl.asProtocol(WithOptionalCodeBlockSyntax.self)?.body {
            trailingTokens += [memberBlock.leftBrace, memberBlock.rightBrace]
        }
        if let block = decl.asProtocol(DeclGroupSyntax.self)?.memberBlock {
            trailingTokens += [block.leftBrace, block.rightBrace]
        }

        let leading = tokens.flatMap { $0.leadingTrivia.offsetPieces(startingAt: $0.position.utf8Offset) }
        let trailing = trailingTokens.flatMap { $0.trailingTrivia.offsetPieces(startingAt: $0.endPositionBeforeTrailingTrivia.utf8Offset) }
        var seen = Set<Int>()
        return (leading + trailing).filter { $0.piece.commentText != nil && seen.insert($0.offset).inserted }
    }
}

/// An `ignore` comment command, as the scan reads it.
enum IgnoreCommand: Equatable {
    case declaration
    case parameters([String])

    init?(comment: TriviaPiece) {
        guard let (text, markerLength) = comment.commentText else { return nil }

        let body = text.dropFirst(markerLength).replacingOccurrences(of: "*/", with: "")
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard let prefix = ["outskirts:", "periphery:"].first(where: { trimmed.hasPrefix($0) }) else { return nil }

        let command = String(trimmed.dropFirst(prefix.count).split(separator: "-").first ?? "").trimmingCharacters(in: .whitespaces)
        if command == "ignore" {
            self = .declaration
        } else if command.hasPrefix("ignore:parameters"),
                  let list = command.split(separator: " ").last, list != "ignore:parameters"
        {
            self = .parameters(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        } else {
            return nil
        }
    }
}
