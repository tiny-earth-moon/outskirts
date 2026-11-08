import Foundation
import Shared
import SourceGraph
import SwiftSyntax

/// Collects the Swift expressions that name a Metal function: the `name:` argument of `makeFunction(name:)` and its
/// variants, and of `MTLFunctionStitchingFunctionNode(name:)`, and the value assigned to a `name` property.
///
/// Only an assignment to `MTLFunctionDescriptor.name` names a Metal function, which the indexer confirms from the
/// index store at the position of the `name` token.
///
/// SwiftUI looks a shader up by name through `ShaderLibrary`: a dynamic member (`ShaderLibrary.default.ripple`,
/// `ShaderLibrary.bundle(.module).ripple`, `ShaderLibrary.ripple`), its `[dynamicMember:]` subscript, and the `name:`
/// argument of `ShaderFunction(library:name:)` name a Metal function too.
///
/// It also collects the calls that create a Metal library from something other than the `.metal` files of the
/// project: `makeLibrary(source:)`, `makeLibrary(URL:)`, `makeLibrary(filepath:)`, `makeLibrary(data:)`,
/// `makeLibrary(stitchedDescriptor:)`, and anything involving an `MTLBinaryArchive`.
public final class MetalFunctionNameCollector: PeripherySyntaxVisitor {
    public struct Candidate: Hashable {
        public let reference: MetalFunctionNameReference
        /// The position of the `name` token of an assignment, `nil` for a call, which needs no confirmation.
        public let propertyLocation: Location?
    }

    public struct Result {
        public let candidates: [Candidate]
        public let runtimeLibrarySites: [MetalRuntimeLibrarySite]
    }

    private static let runtimeLibraryLabels: Set = ["source", "URL", "filepath", "data", "stitchedDescriptor"]
    private static let binaryArchiveNames: Set = ["MTLBinaryArchive", "makeBinaryArchive"]

    private static let callNames: Set = ["makeFunction", "MTLFunctionStitchingFunctionNode"]
    private static let shaderLibraryMembers: Set = ["default", "bundle", "init", "self", "Type"]

    private(set) var candidates: [Candidate] = []

    private(set) var runtimeLibrarySites: [MetalRuntimeLibrarySite] = []

    private let sourceLocationBuilder: SourceLocationBuilder

    public init(sourceLocationBuilder: SourceLocationBuilder, swiftVersion _: SwiftVersion) {
        self.sourceLocationBuilder = sourceLocationBuilder
    }

    init(sourceLocationBuilder: SourceLocationBuilder) {
        self.sourceLocationBuilder = sourceLocationBuilder
    }

    static func collect(
        from syntax: SourceFileSyntax,
        file: SourceFile,
        locationConverter: SourceLocationConverter
    ) -> Result {
        let builder = SourceLocationBuilder(file: file, locationConverter: locationConverter)
        let collector = MetalFunctionNameCollector(sourceLocationBuilder: builder)
        collector.walk(syntax)
        return collector.result
    }

    public var result: Result {
        Result(candidates: candidates, runtimeLibrarySites: runtimeLibrarySites)
    }

    public func visit(_ node: FunctionCallExprSyntax) {
        let calleeName: String? = if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self) {
            memberAccess.declName.baseName.text
        } else if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            reference.baseName.text
        } else {
            nil
        }

        if let calleeName, Self.callNames.contains(calleeName),
           let argument = node.arguments.first, argument.label?.text == "name"
        {
            candidates.append(Candidate(reference: reference(to: argument.expression), propertyLocation: nil))
        }

        if calleeName == "ShaderFunction",
           let argument = node.arguments.first(where: { $0.label?.text == "name" })
        {
            candidates.append(Candidate(reference: reference(to: argument.expression), propertyLocation: nil))
        }

        if let calleeName {
            collectRuntimeLibrary(calleeName: calleeName, call: node)
        }
    }

    public func visit(_ node: MemberAccessExprSyntax) {
        guard let base = node.base, Self.isShaderLibrary(base) else { return }

        let name = node.declName.baseName.text
        guard !Self.shaderLibraryMembers.contains(name) else { return }

        let location = sourceLocationBuilder.location(at: node.declName.baseName.positionAfterSkippingLeadingTrivia)
        candidates.append(Candidate(reference: MetalFunctionNameReference(name: name, location: location), propertyLocation: nil))
    }

    public func visit(_ node: SubscriptCallExprSyntax) {
        guard Self.isShaderLibrary(node.calledExpression),
              let argument = node.arguments.first, argument.label?.text == "dynamicMember"
        else { return }

        candidates.append(Candidate(reference: reference(to: argument.expression), propertyLocation: nil))
    }

    public func visit(_ node: IdentifierTypeSyntax) {
        if node.name.text == "MTLBinaryArchive" {
            addRuntimeLibrarySite(call: "MTLBinaryArchive", at: node.positionAfterSkippingLeadingTrivia)
        }
    }

    public func visit(_ node: SequenceExprSyntax) {
        let elements = Array(node.elements)

        for (index, element) in elements.enumerated() where element.is(AssignmentExprSyntax.self) {
            guard index > 0, index + 1 < elements.count else { continue }

            collectAssignment(to: elements[index - 1], value: elements[index + 1])
        }
    }

    public func visit(_ node: InfixOperatorExprSyntax) {
        if node.operator.is(AssignmentExprSyntax.self) {
            collectAssignment(to: node.leftOperand, value: node.rightOperand)
        }
    }

    // MARK: - Private

    /// Whether the expression is a SwiftUI shader library: `ShaderLibrary`, `ShaderLibrary.default`,
    /// `ShaderLibrary.bundle(_:)` or `ShaderLibrary(url:)`.
    private static func isShaderLibrary(_ expression: ExprSyntax) -> Bool {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text == "ShaderLibrary"
        }
        if let memberAccess = expression.as(MemberAccessExprSyntax.self), let base = memberAccess.base {
            return memberAccess.declName.baseName.text == "default" && isShaderLibrary(base)
        }
        if let call = expression.as(FunctionCallExprSyntax.self) {
            if let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self), let base = memberAccess.base {
                return ["bundle", "init"].contains(memberAccess.declName.baseName.text) && isShaderLibrary(base)
            }
            return isShaderLibrary(call.calledExpression)
        }
        return false
    }

    private func collectRuntimeLibrary(calleeName: String, call node: FunctionCallExprSyntax) {
        let position = node.positionAfterSkippingLeadingTrivia

        if calleeName == "makeLibrary", let label = node.arguments.first?.label?.text,
           Self.runtimeLibraryLabels.contains(label)
        {
            addRuntimeLibrarySite(call: "makeLibrary(\(label):)", at: position)
        } else if Self.binaryArchiveNames.contains(calleeName) {
            addRuntimeLibrarySite(call: calleeName, at: position)
        }
    }

    private func addRuntimeLibrarySite(call: String, at position: AbsolutePosition) {
        runtimeLibrarySites.append(MetalRuntimeLibrarySite(call: call, location: sourceLocationBuilder.location(at: position)))
    }

    private func collectAssignment(to target: ExprSyntax, value: ExprSyntax) {
        guard let memberAccess = target.as(MemberAccessExprSyntax.self),
              memberAccess.base != nil,
              memberAccess.declName.baseName.text == "name"
        else { return }

        let propertyLocation = sourceLocationBuilder.location(at: memberAccess.declName.baseName.positionAfterSkippingLeadingTrivia)
        candidates.append(Candidate(reference: reference(to: value), propertyLocation: propertyLocation))
    }

    private func reference(to expression: ExprSyntax) -> MetalFunctionNameReference {
        let location = sourceLocationBuilder.location(at: expression.positionAfterSkippingLeadingTrivia)
        let name = expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
        return MetalFunctionNameReference(name: name, location: location)
    }
}
