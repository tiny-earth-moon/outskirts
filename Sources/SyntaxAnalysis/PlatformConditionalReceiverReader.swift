import SourceGraph
import SwiftSyntax

/// Reads, in a platform conditional clause, the receiver each member is written on: what its syntax tells of the
/// receiver's type, which the source graph resolves (see `PlatformConditionalReceiverResolver`).
///
/// A value tells its type only when the clause binds it, with an annotation or an initializer the clause writes. A
/// value bound outside the clause (a parameter or a local of the enclosing function), a generic parameter, or a type
/// the clause declares or aliases does not.
final class PlatformConditionalReceiverReader {
    private static let maximumDepth = 8

    private let clause: IfConfigClauseSyntax
    private lazy var clauseBindings: [String: [Binding]] = {
        let finder = BindingFinder(viewMode: .sourceAccurate)
        finder.walk(clause)
        return finder.bindings
    }()

    private lazy var outsideBoundNames: Set<String> = {
        var names: Set<String> = []
        var scope = Syntax(clause)
        var isInScope = true
        var parent = clause.parent

        // The generic parameters of every enclosing declaration, and the names bound in the declaration that
        // contains the clause.
        while let current = parent {
            if let generic = current.asProtocol(WithGenericParametersSyntax.self)?.genericParameterClause {
                names.formUnion(generic.parameters.map { Self.text($0.name) })
            }
            if current.is(MemberBlockItemSyntax.self) || current.is(SourceFileSyntax.self) {
                isInScope = false
            }
            if isInScope {
                scope = current
                if current.is(CodeBlockItemSyntax.self), current.parent?.parent?.is(SourceFileSyntax.self) ?? false {
                    isInScope = false
                }
            }
            parent = current.parent
        }

        let finder = BindingFinder(viewMode: .sourceAccurate)
        finder.walk(scope)
        return names.union(finder.bindings.keys)
    }()

    init(clause: IfConfigClauseSyntax) {
        self.clause = clause
    }

    /// The use of the member the identifier names, or nil when no receiver scopes it: a type, an implicit member, or
    /// a name written bare outside the types the clause declares.
    func memberUse(of token: TokenSyntax, named name: String) -> PlatformConditionalMemberUse? {
        guard case .identifier = token.tokenKind, let reference = token.parent?.as(DeclReferenceExprSyntax.self) else {
            return nil
        }

        if let member = reference.parent?.as(MemberAccessExprSyntax.self), member.declName.id == reference.id {
            guard let base = member.base else { return nil }

            return PlatformConditionalMemberUse(
                name: name,
                receiver: receiver(of: base, depth: 0),
                lexicalTypeNames: lexicalTypeNames(of: Syntax(reference))
            )
        }

        guard !(reference.parent?.is(KeyPathPropertyComponentSyntax.self) ?? false) else { return nil }

        let types = enclosingTypeNames(of: Syntax(reference))
        guard !types.isEmpty else { return nil }

        return PlatformConditionalMemberUse(
            name: name,
            receiver: .enclosingTypes(types),
            isBare: true,
            lexicalTypeNames: lexicalTypeNames(of: Syntax(reference))
        )
    }

    // MARK: - Private

    private func receiver(of expression: ExprSyntax, depth: Int) -> PlatformConditionalReceiver {
        guard depth < Self.maximumDepth else { return .unknown }

        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            guard reference.argumentNames == nil else { return .unknown }

            switch reference.baseName.tokenKind {
            case .keyword(.self), .keyword(.Self):
                return enclosingTypesReceiver(of: Syntax(reference))
            case .identifier:
                return receiver(ofIdentifier: Self.text(reference.baseName), depth: depth)
            default:
                return .unknown
            }
        }
        if expression.is(SuperExprSyntax.self) {
            return enclosingTypesReceiver(of: Syntax(expression))
        }
        if let member = expression.as(MemberAccessExprSyntax.self) {
            guard let base = member.base, case .identifier = member.declName.baseName.tokenKind,
                  member.declName.argumentNames == nil
            else { return .unknown }

            return .member(receiver(of: base, depth: depth + 1), Self.text(member.declName.baseName))
        }
        if let call = expression.as(FunctionCallExprSyntax.self) {
            return receiver(of: call, depth: depth)
        }
        if let specialization = expression.as(GenericSpecializationExprSyntax.self) {
            return receiver(of: specialization.expression, depth: depth + 1)
        }
        if let inner = Self.wrappedExpression(of: expression) {
            return receiver(of: inner, depth: depth + 1)
        }
        if let type = Self.castType(of: expression) {
            return receiver(ofType: type)
        }
        if Self.isLiteral(expression) || expression.is(ArrayExprSyntax.self) || expression.is(DictionaryExprSyntax.self) {
            return .literal
        }
        return .unknown
    }

    private func receiver(of call: FunctionCallExprSyntax, depth: Int) -> PlatformConditionalReceiver {
        let hasOnlyLiteralArguments = call.trailingClosure == nil && call.additionalTrailingClosures.isEmpty
            && call.arguments.allSatisfy { Self.isLiteral($0.expression) }
        var callee = call.calledExpression
        // `T.init(...)` constructs `T`.
        if let member = callee.as(MemberAccessExprSyntax.self), member.declName.baseName.tokenKind == .keyword(.`init`),
           let base = member.base
        {
            callee = base
        }
        return .call(receiver(of: callee, depth: depth + 1), hasOnlyLiteralArguments: hasOnlyLiteralArguments)
    }

    private func receiver(ofIdentifier name: String, depth: Int) -> PlatformConditionalReceiver {
        if let bindings = clauseBindings[name] {
            guard bindings.count == 1, let binding = bindings.first else { return .unknown }

            switch binding {
            case let .annotated(type):
                return receiver(ofType: type)
            case let .initialized(value):
                return .inferred(receiver(of: value, depth: depth + 1))
            case .opaque:
                return .unknown
            }
        }

        return outsideBoundNames.contains(name) ? .unknown : .name(name)
    }

    private func receiver(ofType type: TypeSyntax) -> PlatformConditionalReceiver {
        if let optional = type.as(OptionalTypeSyntax.self) {
            return receiver(ofType: optional.wrappedType)
        }
        if let optional = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            return receiver(ofType: optional.wrappedType)
        }
        if let attributed = type.as(AttributedTypeSyntax.self) {
            return receiver(ofType: attributed.baseType)
        }
        if let someOrAny = type.as(SomeOrAnyTypeSyntax.self) {
            return receiver(ofType: someOrAny.constraint)
        }
        if type.is(ArrayTypeSyntax.self) {
            return .typeName("Array")
        }
        if type.is(DictionaryTypeSyntax.self) {
            return .typeName("Dictionary")
        }

        let name: String
        if let identifier = type.as(IdentifierTypeSyntax.self) {
            if identifier.name.tokenKind == .keyword(.Self) {
                return enclosingTypesReceiver(of: Syntax(identifier))
            }
            name = Self.text(identifier.name)
        } else if let member = type.as(MemberTypeSyntax.self) {
            name = Self.text(member.name)
        } else {
            return .unknown
        }

        // A generic parameter, or a type the clause declares or aliases.
        guard clauseBindings[name] == nil, !outsideBoundNames.contains(name) else { return .unknown }

        return .typeName(name)
    }

    private func enclosingTypesReceiver(of node: Syntax) -> PlatformConditionalReceiver {
        let types = enclosingTypeNames(of: node)
        return types.isEmpty ? .unknown : .enclosingTypes(types)
    }

    /// The names of the types declared or extended in the clause that contain the node, innermost first.
    private func enclosingTypeNames(of node: Syntax) -> [String] {
        typeNames(around: node, upTo: clause.id)
    }

    /// The names of the types declared or extended around the node, in the clause or not, innermost first.
    private func lexicalTypeNames(of node: Syntax) -> [String] {
        typeNames(around: node, upTo: nil)
    }

    private func typeNames(around node: Syntax, upTo limit: SyntaxIdentifier?) -> [String] {
        var result: [String] = []
        var parent = node.parent

        while let current = parent, current.id != limit {
            if let name = Self.declaredTypeName(of: current) {
                result.append(name)
            }
            parent = current.parent
        }

        return result
    }

    private static func declaredTypeName(of node: Syntax) -> String? {
        if let decl = node.as(StructDeclSyntax.self) {
            return text(decl.name)
        }
        if let decl = node.as(ClassDeclSyntax.self) {
            return text(decl.name)
        }
        if let decl = node.as(EnumDeclSyntax.self) {
            return text(decl.name)
        }
        if let decl = node.as(ActorDeclSyntax.self) {
            return text(decl.name)
        }
        if let decl = node.as(ProtocolDeclSyntax.self) {
            return text(decl.name)
        }
        if let decl = node.as(ExtensionDeclSyntax.self) {
            if let identifier = decl.extendedType.as(IdentifierTypeSyntax.self) {
                return text(identifier.name)
            }
            if let member = decl.extendedType.as(MemberTypeSyntax.self) {
                return text(member.name)
            }
        }
        return nil
    }

    /// The expression that parentheses, `?`, `!`, `try` or `await` wrap.
    private static func wrappedExpression(of expression: ExprSyntax) -> ExprSyntax? {
        if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1, let element = tuple.elements.first,
           element.label == nil
        {
            return element.expression
        }
        if let optional = expression.as(OptionalChainingExprSyntax.self) {
            return optional.expression
        }
        if let unwrap = expression.as(ForceUnwrapExprSyntax.self) {
            return unwrap.expression
        }
        if let tryExpression = expression.as(TryExprSyntax.self) {
            return tryExpression.expression
        }
        if let awaitExpression = expression.as(AwaitExprSyntax.self) {
            return awaitExpression.expression
        }
        return nil
    }

    /// The type of `value as? T` or `value as! T`.
    private static func castType(of expression: ExprSyntax) -> TypeSyntax? {
        if let cast = expression.as(AsExprSyntax.self), cast.questionOrExclamationMark != nil {
            return cast.type
        }
        guard let sequence = expression.as(SequenceExprSyntax.self), sequence.elements.count == 3 else { return nil }

        let elements = Array(sequence.elements)
        guard let cast = elements[1].as(UnresolvedAsExprSyntax.self), cast.questionOrExclamationMark != nil,
              let type = elements[2].as(TypeExprSyntax.self)
        else { return nil }

        return type.type
    }

    private static func isLiteral(_ expression: ExprSyntax) -> Bool {
        if let prefix = expression.as(PrefixOperatorExprSyntax.self) {
            return prefix.operator.text == "-" && isLiteral(prefix.expression)
        }
        return expression.is(StringLiteralExprSyntax.self) || expression.is(IntegerLiteralExprSyntax.self)
            || expression.is(FloatLiteralExprSyntax.self) || expression.is(BooleanLiteralExprSyntax.self)
            || expression.is(NilLiteralExprSyntax.self)
    }

    fileprivate static func text(_ token: TokenSyntax) -> String {
        token.identifier?.name ?? token.text
    }
}

/// What a binding tells of the type of the value it binds.
private enum Binding {
    case annotated(TypeSyntax)
    case initialized(ExprSyntax)
    /// A binding that tells nothing: a pattern without an initializer, a closure parameter without a type, a generic
    /// parameter, or a type or function of that name.
    case opaque
}

/// Collects the names a syntax tree binds.
private final class BindingFinder: SyntaxVisitor {
    private(set) var bindings: [String: [Binding]] = [:]

    private func insert(_ token: TokenSyntax, _ binding: Binding) {
        bindings[PlatformConditionalReceiverReader.text(token), default: []].append(binding)
    }

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        if let binding = node.parent?.as(PatternBindingSyntax.self), !Self.isLocal(binding) {
            // A property or a global: a name written bare in a type may refer to one of its members instead.
            insert(node.identifier, .opaque)
        } else if let binding = node.parent?.as(PatternBindingSyntax.self) {
            if let type = binding.typeAnnotation?.type {
                insert(node.identifier, .annotated(type))
            } else if let value = binding.initializer?.value {
                insert(node.identifier, .initialized(value))
            } else {
                insert(node.identifier, .opaque)
            }
        } else if let condition = node.parent?.as(OptionalBindingConditionSyntax.self) {
            if let type = condition.typeAnnotation?.type {
                insert(node.identifier, .annotated(type))
            } else if let value = condition.initializer?.value {
                insert(node.identifier, .initialized(value))
            }
            // `if let value` unwraps the value bound outside.
        } else {
            insert(node.identifier, .opaque)
        }
        return .visitChildren
    }

    /// Whether the binding declares a local variable, in the body of a function, a closure or an accessor.
    private static func isLocal(_ binding: PatternBindingSyntax) -> Bool {
        var parent = binding.parent
        while let current = parent {
            if current.is(MemberBlockItemSyntax.self) || current.is(SourceFileSyntax.self) {
                return false
            }
            if current.is(CodeBlockSyntax.self) || current.is(ClosureExprSyntax.self) || current.is(AccessorBlockSyntax.self) {
                return true
            }
            parent = current.parent
        }
        return false
    }

    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        insert(node.secondName ?? node.firstName, node.ellipsis == nil ? .annotated(node.type) : .opaque)
        return .visitChildren
    }

    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        insert(node.secondName ?? node.firstName, node.type.map { .annotated($0) } ?? .opaque)
        return .visitChildren
    }

    override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
        insert(node.name, .opaque)
        return .visitChildren
    }

    override func visit(_ node: GenericParameterSyntax) -> SyntaxVisitorContinueKind {
        insert(node.name, .opaque)
        return .visitChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        insert(node.name, .opaque)
        return .visitChildren
    }

    override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        insert(node.name, .opaque)
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        insert(node.name, .opaque)
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        insert(node.name, .opaque)
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        insert(node.name, .opaque)
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        insert(node.name, .opaque)
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        insert(node.name, .opaque)
        return .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        insert(node.name, .opaque)
        return .visitChildren
    }
}
