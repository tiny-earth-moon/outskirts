import SwiftSyntax

/// Collects the string literals a body may return: the operands of its `return` statements and the value of a
/// single-expression body, through the branches of ternaries, `??`, `if` and `switch` expressions. Literals in
/// conditions, assignments, call arguments, closures and local declarations are not returned values.
final class ReturnedLiteralCollector: SyntaxAnyVisitor {
    private var keys: Set<String> = []

    static func collect(in node: some SyntaxProtocol) -> Set<String> {
        let collector = ReturnedLiteralCollector(viewMode: .sourceAccurate)

        for body in bodies(of: Syntax(node)) {
            collector.collect(body)
        }

        return collector.keys
    }

    /// The statements whose value or `return` statements are returned: a body, the getter of an accessor block, or
    /// each branch of an `if` or `switch` expression.
    private static func bodies(of node: Syntax) -> [CodeBlockItemListSyntax] {
        if let items = node.as(CodeBlockItemListSyntax.self) {
            return [items]
        }

        if let block = node.as(CodeBlockSyntax.self) {
            return [block.statements]
        }

        if let accessorBlock = node.as(AccessorBlockSyntax.self) {
            switch accessorBlock.accessors {
            case let .getter(items):
                return [items]
            case let .accessors(accessors):
                return accessors.filter { $0.accessorSpecifier.tokenKind == .keyword(.get) }.compactMap(\.body?.statements)
            }
        }

        if let ifExpression = node.as(IfExprSyntax.self) {
            var bodies = [ifExpression.body.statements]

            switch ifExpression.elseBody {
            case let .codeBlock(block):
                bodies.append(block.statements)
            case let .ifExpr(elseIf):
                bodies += Self.bodies(of: Syntax(elseIf))
            case nil:
                break
            }

            return bodies
        }

        if let switchExpression = node.as(SwitchExprSyntax.self) {
            return switchExpression.cases.compactMap { $0.as(SwitchCaseSyntax.self)?.statements }
        }

        return []
    }

    private func collect(_ items: CodeBlockItemListSyntax) {
        if items.count == 1, let item = items.first {
            switch item.item {
            case let .expr(expression):
                keys.formUnion(LocalizedStringSyntaxVisitor.literalKeys(in: expression))
            case let .stmt(statement):
                if let expression = statement.as(ExpressionStmtSyntax.self)?.expression {
                    keys.formUnion(LocalizedStringSyntaxVisitor.literalKeys(in: expression))
                }
            case .decl:
                break
            }
        }

        walk(items)
    }

    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        if let expression = node.expression {
            keys.formUnion(LocalizedStringSyntaxVisitor.literalKeys(in: expression))
        }
        return .skipChildren
    }

    /// `return` statements of closures and local declarations return from them, not from the body.
    override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
        if node.is(ClosureExprSyntax.self) || (node.isProtocol(DeclSyntaxProtocol.self) && !node.is(IfConfigDeclSyntax.self)) {
            return .skipChildren
        }
        return .visitChildren
    }
}
