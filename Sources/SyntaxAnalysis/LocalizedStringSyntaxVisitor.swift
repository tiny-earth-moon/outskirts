import Foundation
import Shared
import SwiftSyntax

/// Collects string keys used for localization in Swift source files.
///
/// Keys are collected in two ways:
/// - `usedStringKeys` holds keys that are known to be used from syntax alone:
///   - `NSLocalizedString("key", ...)`, `String(localized: "key", ...)`, `LocalizedStringKey("key")`,
///     `LocalizedStringResource("key", ...)`, `Text("key")`, `Bundle.localizedString(forKey: "key", ...)` and
///     `Bundle.localizedAttributedString(forKey: "key", ...)`, including the explicit `.init` and `stringLiteral:`
///     forms of the initializers (e.g. `LocalizedStringKey.init("key")`,
///     `String.LocalizationValue(stringLiteral: "key")`).
///   - AppIntents `@Parameter(title:)` / `@Property(title:)` attribute arguments.
///   - Literals assigned to, returned from, or used as the default value of a declaration whose type is a
///     localized type (e.g. `let title: LocalizedStringResource = "key"`).
///   - Literals passed to a call whose callee cannot be located syntactically (conservatively retained).
/// - `callSites` holds the remaining calls, subscript calls included, that receive string literals. Whether those
///   literals are keys depends on the type of the receiving parameter, which is resolved from the index store by the
///   indexer.
/// - `unresolvedKeys` holds the lookups whose key is built from a runtime value, with the literal prefix of the key
///   when there is one.
public final class LocalizedStringSyntaxVisitor: PeripherySyntaxVisitor {
    /// Type names whose values are created from a localization key when initialized from a string literal.
    public static let localizedTypeNames = [
        "LocalizedStringKey",
        "LocalizedStringResource",
        "LocalizationValue",
        "DisplayRepresentation",
        "IntentDescription",
        "IntentDialog",
        "ParameterSummaryString",
        "AppShortcutPhrase",
    ]

    /// AppIntents property wrappers whose arguments take a localization key as a string literal.
    private static let localizedAttributeNames: Set = ["Parameter", "Property"]
    private static let localizedAttributeLabels: Set = [
        "title", "description", "requestValueDialog", "requestConfirmationDialog", "requestDisambiguationDialog",
    ]

    /// `Bundle` methods looking a key up with their `forKey:` argument.
    private static let bundleLookupNames: Set = ["localizedString", "localizedAttributedString"]

    public private(set) var usedStringKeys: Set<String> = []
    public private(set) var callSites: [LocalizedStringCallSite] = []
    public private(set) var unresolvedKeys: [LocalizedStringUnresolvedKey] = []

    private let sourceLocationBuilder: SourceLocationBuilder

    public init(sourceLocationBuilder: SourceLocationBuilder, swiftVersion _: SwiftVersion) {
        self.sourceLocationBuilder = sourceLocationBuilder
    }

    /// Whether values of the type are created from a localization key. For a function type, only its return type
    /// counts: a closure taking a `LocalizedStringKey` and returning a `String` does not return a key.
    public static func isLocalizedType(_ typeName: String) -> Bool {
        let valueType = valueTypeName(of: typeName)
        return localizedTypeNames.contains { valueType.contains($0) }
    }

    /// The return type of a function type, looking through attributes and an optional function type, e.g.
    /// `Swift.String` for `@escaping (SwiftUI.LocalizedStringKey) -> Swift.String`; any other type unchanged.
    static func valueTypeName(of typeName: String) -> String {
        var type = typeName.trimmingCharacters(in: .whitespaces)

        while type.hasPrefix("@"), let space = type.firstIndex(of: " ") {
            type = type[space...].trimmingCharacters(in: .whitespaces)
        }

        let characters = Array(type)
        var depth = 0
        var lastArrow: Int?

        for index in characters.indices {
            switch characters[index] {
            case "(", "[", "<":
                depth += 1
            case ")", "]":
                depth -= 1
            case ">" where index > 0 && characters[index - 1] == "-":
                if depth == 0 {
                    lastArrow = index
                }
            case ">":
                depth -= 1
            default:
                break
            }
        }

        if let lastArrow {
            return valueTypeName(of: String(characters[(lastArrow + 1)...]))
        }

        // An optional function type, `(() -> T)?`.
        if characters.first == "(", characters.count > 2, ["?", "!"].contains(characters.last),
           characters[characters.count - 2] == ")"
        {
            let inner = String(characters[1 ..< (characters.count - 2)])
            if inner.contains("->") {
                return valueTypeName(of: inner)
            }
        }

        return type
    }

    public func visit(_ node: FunctionCallExprSyntax) {
        collectKnownCallKeys(node)
        collectCallSite(
            arguments: node.arguments,
            trailingClosure: node.trailingClosure,
            additionalTrailingClosures: node.additionalTrailingClosures,
            calleeToken: calleeNameToken(of: node.calledExpression)
        )
        collectUnresolvedKey(node)
    }

    /// `table["key"]`: the index store records the reference to the subscript accessor at the opening bracket.
    public func visit(_ node: SubscriptCallExprSyntax) {
        collectCallSite(
            arguments: node.arguments,
            trailingClosure: node.trailingClosure,
            additionalTrailingClosures: node.additionalTrailingClosures,
            calleeToken: node.leftSquare
        )
    }

    /// `@Parameter(title: "key")` is an attribute rather than a call, so it is invisible to call site resolution.
    public func visit(_ node: AttributeSyntax) {
        guard let name = node.attributeName.as(IdentifierTypeSyntax.self)?.name.text,
              Self.localizedAttributeNames.contains(name),
              case let .argumentList(arguments) = node.arguments
        else { return }

        for argument in arguments {
            guard let label = argument.label?.text, Self.localizedAttributeLabels.contains(label) else { continue }

            insertLiteral(argument.expression)
        }
    }

    /// A literal cast to a localized type, `"key" as LocalizedStringKey`, is a key wherever it appears.
    public func visit(_ node: SequenceExprSyntax) {
        let elements = Array(node.elements)

        for index in elements.indices.dropFirst().dropLast() {
            guard let cast = elements[index].as(UnresolvedAsExprSyntax.self), cast.questionOrExclamationMark == nil,
                  let type = elements[index + 1].as(TypeExprSyntax.self),
                  Self.isLocalizedType(type.type.trimmedDescription)
            else { continue }

            insertLiteral(elements[index - 1])
        }
    }

    public func visit(_ node: VariableDeclSyntax) {
        for binding in node.bindings {
            guard let type = binding.typeAnnotation?.type, Self.isLocalizedType(type.trimmedDescription) else { continue }

            if let value = binding.initializer?.value {
                usedStringKeys.formUnion(literalKeys(in: value, ofType: type))
            }

            if let accessorBlock = binding.accessorBlock {
                usedStringKeys.formUnion(ReturnedLiteralCollector.collect(in: accessorBlock))
            }
        }
    }

    public func visit(_ node: FunctionDeclSyntax) {
        collectDefaultValueKeys(node.signature.parameterClause)

        if let returnType = node.signature.returnClause?.type,
           Self.isLocalizedType(returnType.trimmedDescription),
           let body = node.body
        {
            usedStringKeys.formUnion(ReturnedLiteralCollector.collect(in: body))
        }
    }

    public func visit(_ node: InitializerDeclSyntax) {
        collectDefaultValueKeys(node.signature.parameterClause)
    }

    /// The default value of an associated value, `case title(LocalizedStringKey = "key")`, and the raw value of a case
    /// whose raw type is a localized type, `enum Title: LocalizedStringKey { case greeting = "key" }`.
    public func visit(_ node: EnumCaseDeclSyntax) {
        let rawType = node.parent?.ancestorOrSelf { $0.as(EnumDeclSyntax.self) }?.inheritanceClause?.inheritedTypes.first?.type

        for element in node.elements {
            for parameter in element.parameterClause?.parameters ?? [] {
                guard let value = parameter.defaultValue?.value else { continue }

                usedStringKeys.formUnion(literalKeys(in: value, ofType: parameter.type))
            }

            if let rawType, let rawValue = element.rawValue?.value {
                usedStringKeys.formUnion(literalKeys(in: rawValue, ofType: rawType))
            }
        }
    }

    public func visit(_ node: SubscriptDeclSyntax) {
        collectDefaultValueKeys(node.parameterClause)

        if Self.isLocalizedType(node.returnClause.type.trimmedDescription), let accessorBlock = node.accessorBlock {
            usedStringKeys.formUnion(ReturnedLiteralCollector.collect(in: accessorBlock))
        }
    }

    // MARK: - Private

    private func collectDefaultValueKeys(_ clause: FunctionParameterClauseSyntax) {
        for parameter in clause.parameters {
            guard Self.isLocalizedType(parameter.type.trimmedDescription),
                  let value = parameter.defaultValue?.value
            else { continue }

            usedStringKeys.formUnion(literalKeys(in: value, ofType: parameter.type))
        }
    }

    /// String literals of an expression that initialize a value of a localized type, matching tuple, array and
    /// dictionary literals against the corresponding element types of `type` (e.g. only the first element of
    /// `("key", "symbol")` for `(LocalizedStringKey, String)`).
    private func literalKeys(in expression: ExprSyntax, ofType type: TypeSyntax) -> [String] {
        if let optional = type.as(OptionalTypeSyntax.self) {
            return literalKeys(in: expression, ofType: optional.wrappedType)
        }

        if let optional = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            return literalKeys(in: expression, ofType: optional.wrappedType)
        }

        if let tupleType = type.as(TupleTypeSyntax.self) {
            if tupleType.elements.count == 1, let element = tupleType.elements.first {
                return literalKeys(in: expression, ofType: element.type)
            }

            if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == tupleType.elements.count {
                return zip(tuple.elements, tupleType.elements).flatMap { literalKeys(in: $0.expression, ofType: $1.type) }
            }
        }

        if let arrayType = type.as(ArrayTypeSyntax.self), let array = expression.as(ArrayExprSyntax.self) {
            return array.elements.flatMap { literalKeys(in: $0.expression, ofType: arrayType.element) }
        }

        if let dictionaryType = type.as(DictionaryTypeSyntax.self),
           let dictionary = expression.as(DictionaryExprSyntax.self)
        {
            guard case let .elements(elements) = dictionary.content else { return [] }

            return elements.flatMap {
                literalKeys(in: $0.key, ofType: dictionaryType.key) + literalKeys(in: $0.value, ofType: dictionaryType.value)
            }
        }

        guard Self.isLocalizedType(type.trimmedDescription) else { return [] }

        return Self.literalKeys(in: expression)
    }

    /// `calleeToken` is the token where the index store records the reference to the callee, nil when it cannot be
    /// located syntactically.
    private func collectCallSite(
        arguments argumentList: LabeledExprListSyntax,
        trailingClosure: ClosureExprSyntax?,
        additionalTrailingClosures: MultipleTrailingClosureElementListSyntax,
        calleeToken: TokenSyntax?
    ) {
        var arguments = argumentList.map { argument in
            LocalizedStringCallSite.Argument(label: argument.label?.text, keys: Self.literalKeys(in: argument.expression))
        }

        // Trailing closures come last, those returning no literal are left out.
        if let trailingClosure {
            let keys = Self.literalKeys(in: ExprSyntax(trailingClosure))
            if !keys.isEmpty {
                arguments.append(LocalizedStringCallSite.Argument(label: nil, keys: keys, isTrailingClosure: true))
            }
        }

        for closure in additionalTrailingClosures {
            let keys = Self.literalKeys(in: ExprSyntax(closure.closure))
            if !keys.isEmpty {
                let label = closure.label.text
                arguments.append(LocalizedStringCallSite.Argument(label: label == "_" ? nil : label, keys: keys))
            }
        }

        guard arguments.contains(where: { !$0.keys.isEmpty }) else { return }
        guard let calleeToken else {
            // The callee cannot be resolved, conservatively assume the literals are keys.
            usedStringKeys.formUnion(arguments.flatMap(\.keys))
            return
        }

        let location = sourceLocationBuilder.location(at: calleeToken.positionAfterSkippingLeadingTrivia)
        callSites.append(LocalizedStringCallSite(line: location.line, column: location.column, arguments: arguments))
    }

    private func calleeNameToken(of expression: ExprSyntax) -> TokenSyntax? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return reference.baseName
        }

        if let memberAccess = expression.as(MemberAccessExprSyntax.self) {
            return memberAccess.declName.baseName
        }

        if let specialization = expression.as(GenericSpecializationExprSyntax.self) {
            return calleeNameToken(of: specialization.expression)
        }

        return nil
    }

    /// Detects well-known localization APIs by name. These are retained regardless of index store resolution.
    private func collectKnownCallKeys(_ node: FunctionCallExprSyntax) {
        let calledExpression = node.calledExpression

        if let name = Self.knownCalleeName(of: calledExpression) {
            // `Text(optionalString ?? "literal")` calls the verbatim `Text.init<S: StringProtocol>(_:)`: whether the
            // literal is a key depends on the type of the other operand, left to call site resolution.
            if let keyArgument = Self.keyArgument(of: node, calleeName: name),
               name != "Text" || !Self.containsNilCoalescing(keyArgument)
            {
                insertLiteral(keyArgument)
            }
            return
        }

        // Handle member access like Bundle.main.localizedString(forKey: "key", ...)
        if let memberAccess = calledExpression.as(MemberAccessExprSyntax.self),
           Self.bundleLookupNames.contains(memberAccess.declName.baseName.text),
           let forKeyArg = node.arguments.first(where: { $0.label?.text == "forKey" })
        {
            insertLiteral(forKeyArg.expression)
        }
    }

    /// The name of a called function or type, looking through an explicit initializer reference
    /// (`LocalizedStringKey.init`) and naming `String.LocalizationValue` by its last component.
    private static func knownCalleeName(of expression: ExprSyntax) -> String? {
        if let identifier = expression.as(DeclReferenceExprSyntax.self) {
            return identifier.baseName.text
        }

        guard let memberAccess = expression.as(MemberAccessExprSyntax.self), let base = memberAccess.base else { return nil }

        switch memberAccess.declName.baseName.text {
        case "init":
            return knownCalleeName(of: base)
        case "LocalizationValue" where base.as(DeclReferenceExprSyntax.self)?.baseName.text == "String":
            return "LocalizationValue"
        default:
            return nil
        }
    }

    /// The key argument of a well-known lookup: the first unlabeled argument, the `stringLiteral:` argument of a
    /// localized type initializer, or the `localized:` argument of `String`.
    private static func keyArgument(of node: FunctionCallExprSyntax, calleeName: String) -> ExprSyntax? {
        guard let first = node.arguments.first else { return nil }

        switch calleeName {
        case "NSLocalizedString", "Text":
            return first.label == nil ? first.expression : nil
        case "LocalizedStringKey", "LocalizedStringResource", "LocalizationValue":
            return first.label == nil || first.label?.text == "stringLiteral" ? first.expression : nil
        case "String":
            return node.arguments.first { $0.label?.text == "localized" }?.expression
        default:
            return nil
        }
    }

    // MARK: - Runtime keys

    // Based on agoodkind/periphery@544a77d, 6c57931 and 5c5af4c by Alex Goodkind.

    private func collectUnresolvedKey(_ node: FunctionCallExprSyntax) {
        guard let (keyExpression, acceptsKeyFormat) = runtimeKeyArgument(of: node),
              !resolvesToLiteralKeys(keyExpression, acceptsKeyFormat: acceptsKeyFormat)
        else { return }

        let location = sourceLocationBuilder.location(at: node.positionAfterSkippingLeadingTrivia)
        unresolvedKeys.append(LocalizedStringUnresolvedKey(
            prefix: literalPrefix(of: keyExpression),
            bundleScope: bundleScope(of: node),
            line: location.line,
            column: location.column
        ))
    }

    /// The key argument of the lookups that accept a key built at runtime: `NSLocalizedString(_:)`,
    /// `LocalizedStringKey(_:)`, `LocalizedStringResource(_:)`, `String.LocalizationValue(_:)` (also as `.init` or
    /// `stringLiteral:`), `Bundle.localizedString(forKey:)` and `Bundle.localizedAttributedString(forKey:)`. `acceptsKeyFormat` is false
    /// for the lookups taking a plain `String`, for which an interpolated literal is evaluated at runtime rather than
    /// turned into a format key.
    private func runtimeKeyArgument(of node: FunctionCallExprSyntax) -> (ExprSyntax, Bool)? {
        let calledExpression = node.calledExpression
        let firstUnlabeled = node.arguments.first.flatMap { $0.label == nil ? $0.expression : nil }

        if let name = Self.knownCalleeName(of: calledExpression) {
            guard ["NSLocalizedString", "LocalizedStringKey", "LocalizedStringResource", "LocalizationValue"].contains(name),
                  let keyArgument = Self.keyArgument(of: node, calleeName: name)
            else { return nil }

            return (keyArgument, name != "NSLocalizedString")
        }

        guard let memberAccess = calledExpression.as(MemberAccessExprSyntax.self) else { return nil }

        switch memberAccess.declName.baseName.text {
        case "LocalizationValue":
            return firstUnlabeled.map { ($0, true) }
        case let name where Self.bundleLookupNames.contains(name):
            return node.arguments.first { $0.label?.text == "forKey" }.map { ($0.expression, false) }
        default:
            return nil
        }
    }

    /// Whether every value the expression may evaluate to is a string literal key.
    private func resolvesToLiteralKeys(_ expression: ExprSyntax, acceptsKeyFormat: Bool) -> Bool {
        if let stringLiteral = expression.as(StringLiteralExprSyntax.self) {
            return acceptsKeyFormat || stringLiteral.representedLiteralValue != nil
        }

        if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1, let element = tuple.elements.first {
            return resolvesToLiteralKeys(element.expression, acceptsKeyFormat: acceptsKeyFormat)
        }

        if let ternary = expression.as(TernaryExprSyntax.self) {
            return resolvesToLiteralKeys(ternary.thenExpression, acceptsKeyFormat: acceptsKeyFormat)
                && resolvesToLiteralKeys(ternary.elseExpression, acceptsKeyFormat: acceptsKeyFormat)
        }

        if let sequence = expression.as(SequenceExprSyntax.self) {
            return resolvesToLiteralKeys(Array(sequence.elements)[...], acceptsKeyFormat: acceptsKeyFormat)
        }

        return false
    }

    /// An unfolded ternary, `condition ? "a" : "b"`, possibly nested in its else branch.
    private func resolvesToLiteralKeys(_ elements: ArraySlice<ExprSyntax>, acceptsKeyFormat: Bool) -> Bool {
        if elements.count == 1, let element = elements.first {
            return resolvesToLiteralKeys(element, acceptsKeyFormat: acceptsKeyFormat)
        }

        guard let ternaryIndex = elements.firstIndex(where: { $0.is(UnresolvedTernaryExprSyntax.self) }),
              let ternary = elements[ternaryIndex].as(UnresolvedTernaryExprSyntax.self)
        else { return false }

        let elseElements = elements[(ternaryIndex + 1)...]
        guard !elseElements.isEmpty else { return false }

        return resolvesToLiteralKeys(ternary.thenExpression, acceptsKeyFormat: acceptsKeyFormat)
            && resolvesToLiteralKeys(elseElements, acceptsKeyFormat: acceptsKeyFormat)
    }

    /// The static text at the start of a runtime key: the text before the first interpolation of a literal, or the
    /// left literal of a `+` concatenation. Empty for any other expression.
    private func literalPrefix(of expression: ExprSyntax) -> String {
        if let stringLiteral = expression.as(StringLiteralExprSyntax.self) {
            var prefix = ""

            for segment in stringLiteral.segments {
                guard case let .stringSegment(stringSegment) = segment,
                      let value = stringLiteral.with(\.segments, [.stringSegment(stringSegment)]).representedLiteralValue
                else { break }

                prefix += value
            }

            return prefix
        }

        if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1, let element = tuple.elements.first {
            return literalPrefix(of: element.expression)
        }

        if let sequence = expression.as(SequenceExprSyntax.self) {
            let elements = Array(sequence.elements)

            if elements.count >= 3, elements[1].as(BinaryOperatorExprSyntax.self)?.operator.text == "+" {
                return literalPrefix(of: elements[0])
            }
        }

        if let infix = expression.as(InfixOperatorExprSyntax.self),
           infix.operator.as(BinaryOperatorExprSyntax.self)?.operator.text == "+"
        {
            return literalPrefix(of: infix.leftOperand)
        }

        return ""
    }

    private func bundleScope(of node: FunctionCallExprSyntax) -> LocalizedStringUnresolvedKey.BundleScope {
        if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self),
           Self.bundleLookupNames.contains(memberAccess.declName.baseName.text)
        {
            return Self.isModuleBundle(memberAccess.base) ? .module : .unknown
        }

        let bundle = node.arguments.first { $0.label?.text == "bundle" }?.expression
        return Self.isModuleBundle(bundle) ? .module : .unknown
    }

    /// `.module` or `Bundle.module`.
    private static func isModuleBundle(_ expression: ExprSyntax?) -> Bool {
        guard let memberAccess = expression?.as(MemberAccessExprSyntax.self),
              memberAccess.declName.baseName.text == "module"
        else { return false }
        guard let base = memberAccess.base else { return true }

        return base.as(DeclReferenceExprSyntax.self)?.baseName.text == "Bundle"
    }

    private func insertLiteral(_ expression: ExprSyntax) {
        usedStringKeys.formUnion(Self.literalKeys(in: expression))
    }

    /// The catalogue key of a string literal. An interpolated literal maps to the format key Foundation derives
    /// from it: each interpolation becomes a format specifier (`%lld` for an integer literal, `%lf` for a
    /// floating-point literal, the `specifier:` argument when given, `%@` otherwise) and a literal `%` is escaped
    /// as `%%`. Since the type of an interpolated value is unknown, catalogue keys are matched against interpolated
    /// keys with each specifier treated as a wildcard.
    static func localizationKey(of literal: StringLiteralExprSyntax) -> String? {
        if let value = literal.representedLiteralValue {
            return value
        }

        var key = ""

        for segment in literal.segments {
            switch segment {
            case let .stringSegment(stringSegment):
                let segmentLiteral = literal.with(\.segments, [.stringSegment(stringSegment)])
                guard let value = segmentLiteral.representedLiteralValue else { return nil }

                key += value.replacingOccurrences(of: "%", with: "%%")
            case let .expressionSegment(expressionSegment):
                key += formatSpecifier(for: expressionSegment)
            }
        }

        return key
    }

    private static func formatSpecifier(for segment: ExpressionSegmentSyntax) -> String {
        if let specifier = segment.expressions.first(where: { $0.label?.text == "specifier" }),
           let literal = specifier.expression.as(StringLiteralExprSyntax.self),
           let value = literal.representedLiteralValue
        {
            return value
        }

        guard segment.expressions.count == 1, let expression = segment.expressions.first?.expression else { return "%@" }

        var value = expression
        if let prefix = value.as(PrefixOperatorExprSyntax.self) {
            value = prefix.expression
        }

        if value.is(IntegerLiteralExprSyntax.self) {
            return "%lld"
        }

        if value.is(FloatLiteralExprSyntax.self) {
            return "%lf"
        }

        return "%@"
    }

    /// String literals that an expression may evaluate to, looking through parentheses, ternaries, `??`, `try`,
    /// `await`, tuple, array and dictionary literals, `if`/`switch` expressions and closure bodies. Interpolated
    /// literals are normalized to their format key.
    static func literalKeys(in expression: ExprSyntax) -> [String] {
        if let stringLiteral = expression.as(StringLiteralExprSyntax.self) {
            return localizationKey(of: stringLiteral).map { [$0] } ?? []
        }

        if let tuple = expression.as(TupleExprSyntax.self) {
            // A parenthesized expression, or a tuple whose element types are given by the receiving declaration.
            return tuple.elements.flatMap { literalKeys(in: $0.expression) }
        }

        if let ternary = expression.as(TernaryExprSyntax.self) {
            return literalKeys(in: ternary.thenExpression) + literalKeys(in: ternary.elseExpression)
        }

        if let unresolvedTernary = expression.as(UnresolvedTernaryExprSyntax.self) {
            return literalKeys(in: unresolvedTernary.thenExpression)
        }

        if let sequence = expression.as(SequenceExprSyntax.self) {
            return literalKeys(inSequence: Array(sequence.elements)[...])
        }

        if let tryExpression = expression.as(TryExprSyntax.self) {
            return literalKeys(in: tryExpression.expression)
        }

        if let awaitExpression = expression.as(AwaitExprSyntax.self) {
            return literalKeys(in: awaitExpression.expression)
        }

        if let array = expression.as(ArrayExprSyntax.self) {
            return array.elements.flatMap { literalKeys(in: $0.expression) }
        }

        if let dictionary = expression.as(DictionaryExprSyntax.self),
           case let .elements(elements) = dictionary.content
        {
            return elements.flatMap { literalKeys(in: $0.key) + literalKeys(in: $0.value) }
        }

        // Expressions whose value is the literal returned from a body: `if`/`switch` expressions, closures and
        // immediately applied closures.
        if expression.is(IfExprSyntax.self) || expression.is(SwitchExprSyntax.self) {
            return ReturnedLiteralCollector.collect(in: expression).sorted()
        }

        if let closure = expression.as(ClosureExprSyntax.self) {
            return ReturnedLiteralCollector.collect(in: closure.statements).sorted()
        }

        if let call = expression.as(FunctionCallExprSyntax.self), call.arguments.isEmpty,
           let closure = call.calledExpression.as(ClosureExprSyntax.self)
        {
            return ReturnedLiteralCollector.collect(in: closure.statements).sorted()
        }

        return []
    }

    /// String literals an unfolded operator sequence may evaluate to: the branches of a ternary, whose condition is
    /// every element before it, and the operands of `??`. Operands of any other operator are not values of the
    /// sequence; a literal cast with `as` is handled by `visit(_: SequenceExprSyntax)`.
    private static func literalKeys(inSequence elements: ArraySlice<ExprSyntax>) -> [String] {
        if let ternaryIndex = elements.firstIndex(where: { $0.is(UnresolvedTernaryExprSyntax.self) }),
           let ternary = elements[ternaryIndex].as(UnresolvedTernaryExprSyntax.self)
        {
            return literalKeys(in: ternary.thenExpression) + literalKeys(inSequence: elements[(ternaryIndex + 1)...])
        }

        if let coalescingIndex = elements.firstIndex(where: Self.isNilCoalescingOperator) {
            return literalKeys(inSequence: elements[..<coalescingIndex])
                + literalKeys(inSequence: elements[(coalescingIndex + 1)...])
        }

        guard elements.count == 1, let element = elements.first else { return [] }

        return literalKeys(in: element)
    }

    private static func containsNilCoalescing(_ expression: ExprSyntax) -> Bool {
        expression.tokens(viewMode: .sourceAccurate).contains { $0.tokenKind == .binaryOperator("??") }
    }

    private static func isNilCoalescingOperator(_ expression: ExprSyntax) -> Bool {
        expression.as(BinaryOperatorExprSyntax.self)?.operator.text == "??"
    }
}
