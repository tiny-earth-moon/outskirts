import Configuration
import Foundation
import Shared

final class UsedDeclarationMarker: SourceGraphMutator {
    /// The full pass marks the graph; the non-test pass, run for `report_test_only`, starts only from the roots outside
    /// test files and follows no reference located in one, into `nonTestUsedDeclarations`.
    private enum Pass {
        case full
        case nonTest
    }

    private static let previewableProtocolUsrs: Set<String> = [
        "s:7SwiftUI4ViewP",
        "s:7SwiftUI6WidgetP",
        "s:7SwiftUI13ControlWidgetP",
    ]
    private static let previewableSuperclassUsrs: Set<String> = [
        "c:objc(cs)NSViewController",
        "c:objc(cs)UIViewController",
        "c:objc(cs)NSView",
        "c:objc(cs)UIView",
    ]
    private static let previewProviderUsr = "s:7SwiftUI15PreviewProviderP"

    private let graph: SourceGraph
    private let configuration: Configuration
    private let reportsTestOnly: Bool
    private var nonTestUsedDeclarations: Set<Declaration> = []

    init(graph: SourceGraph, configuration: Configuration, swiftVersion _: SwiftVersion) {
        self.graph = graph
        self.configuration = configuration
        reportsTestOnly = configuration.reportTestOnly
    }

    func mutate() throws {
        removeErroneousProtocolReferences()

        if graph.recordsExplanations {
            markUsedRecordingPredecessors(from: rootsWithPredecessors())
        } else {
            markUsed(graph.retainedDeclarations)
            markUsed(graph.rootReferences.compactMapSet { graph.declaration(withUsr: $0.usr) })
        }

        markLivePreviewExpansionsUsed()

        if reportsTestOnly {
            try markTestOnly()
        }

        ignoreUnusedDescendents(in: graph.rootDeclarations,
                                unusedDeclarations: graph.unusedDeclarations)
    }

    // MARK: - Private

    /// Removes references from protocol member decls to conforming decls that have a dereferenced ancestor.
    private func removeErroneousProtocolReferences() {
        // Evaluate ancestor dereference status from a stable pre-mutation snapshot to avoid
        // order-dependent behavior when iterating sets and removing references.
        let dereferencedDeclarations = graph.allDeclarations.filter {
            !(graph.isRetained($0) || graph.hasReferences(to: $0))
        }

        let dereferencedAncestors = Set(dereferencedDeclarations)
        var referencesToRemove = Set<Reference>()

        for protocolDecl in graph.declarations(ofKind: .protocol) {
            for memberDecl in protocolDecl.declarations {
                for relatedRef in memberDecl.related {
                    guard let relatedDecl = graph.declaration(withUsr: relatedRef.usr) else { continue }

                    let hasDereferencedAncestor = relatedDecl.ancestralDeclarations.contains {
                        dereferencedAncestors.contains($0)
                    }

                    if hasDereferencedAncestor {
                        referencesToRemove.insert(relatedRef)
                    }
                }
            }
        }

        for reference in referencesToRemove {
            graph.remove(reference, discardedBy: Self.self, detail: "protocol requirement to a conforming declaration whose enclosing declaration is unreferenced")
        }
    }

    /// Marks the declarations, and everything reachable from them through references and related references, as
    /// used. The walk uses an explicit worklist because a reference chain can be arbitrarily long and walking it by
    /// recursion overflows the stack.
    private func markUsed(_ declarations: Set<Declaration>, in pass: Pass = .full) {
        var pending = Array(declarations)

        while let declaration = pending.popLast() {
            guard !isUsed(declaration, in: pass) else { continue }

            markUsed(declaration, in: pass)

            if pass == .nonTest {
                pending.append(contentsOf: retainedImplicitMembers(of: declaration))
            }

            // With `every_variant`, a used declaration makes its variant twins used, and their references are followed
            // too: the twins compare equal, so none of them is reached on its own.
            for source in graph.withVariantTwins(declaration) {
                markUsed(source, in: pass)

                for reference in [source.references, source.related].joined() where follows(reference, in: pass) {
                    if let referenced = graph.declaration(withUsr: reference.usr), !isUsed(referenced, in: pass) {
                        if pass == .full {
                            graph.recordUsePredecessor(.reference(reference, from: source), for: referenced)
                        }
                        pending.append(referenced)
                    }
                }
            }
        }
    }

    private func isUsed(_ declaration: Declaration, in pass: Pass) -> Bool {
        switch pass {
        case .full:
            graph.isUsed(declaration)
        case .nonTest:
            nonTestUsedDeclarations.contains(declaration) || declaration.location.file.isTestFile
        }
    }

    private func markUsed(_ declaration: Declaration, in pass: Pass) {
        switch pass {
        case .full:
            graph.markUsed(declaration)
        case .nonTest:
            nonTestUsedDeclarations.insert(declaration)
        }
    }

    /// The non-test pass follows no reference located in a test file, nor the retention of a member that only code in
    /// test files keeps.
    private func follows(_ reference: Reference, in pass: Pass) -> Bool {
        pass == .full || !reference.location.file.isTestFile && !isRetainedForTestsOnly(reference)
    }

    private func isRetainedForTestsOnly(_ reference: Reference) -> Bool {
        guard reference.kind == .retained, !graph.retainedForTestsOnly.isEmpty,
              let declaration = graph.declaration(withUsr: reference.usr)
        else { return false }

        return graph.retainedForTestsOnly.contains(declaration)
    }

    /// Marks test-only the declarations outside test files that the full pass reached and the non-test pass did not,
    /// each with the entry of its chain.
    private func markTestOnly() throws {
        markUsed(nonTestRoots(), in: .nonTest)
        markLivePreviewExpansionsUsed(in: .nonTest)
        try markAssetCatalogSymbolsUsed(in: .nonTest)

        let testOnly = graph.usedDeclarations.filter { !isUsed($0, in: .nonTest) }
        for (declaration, entry) in testOnlyChains(testOnly) {
            graph.markTestOnly(declaration, entry: entry)
        }
    }

    /// The entry of the chain of each test-only declaration. An entry is a test-only declaration that no other one
    /// contains or references outside test files; the other declarations of its chain are reached from it, members and
    /// protocol witnesses included. A cycle that no entry reaches is entered by its first declaration in sort order.
    /// Marks used every generated symbol of an asset that has a used symbol or whose name is referenced as a string,
    /// as `AssetCatalogSymbolMarker` does after the full pass.
    private func markAssetCatalogSymbolsUsed(in pass: Pass) throws {
        for asset in try GeneratedAssetSymbols.assets(in: graph, configuration: configuration)
            where asset.isReferencedByName || asset.declarations.contains(where: { isUsed($0, in: pass) })
        {
            markUsed(Set(asset.declarations), in: pass)
        }
    }

    private func testOnlyChains(_ testOnly: Set<Declaration>) -> [Declaration: Declaration] {
        var successors: [Declaration: [Declaration]] = [:]
        var reached: Set<Declaration> = []
        for declaration in testOnly {
            let next = testOnlySuccessors(of: declaration, in: testOnly)
            successors[declaration] = next
            reached.formUnion(next)
        }

        var entries: [Declaration: Declaration] = [:]
        var cycleEntries: Set<Declaration> = []

        func cover(from entry: Declaration) {
            var pending = [entry]
            while let declaration = pending.popLast() {
                if let current = entries[declaration], current == entry || !cycleEntries.contains(current) {
                    continue
                }
                entries[declaration] = entry
                pending.append(contentsOf: successors[declaration, default: []])
            }
        }

        testOnly.subtracting(reached).sorted().forEach(cover(from:))
        for declaration in testOnly.sorted() where entries[declaration] == nil {
            cycleEntries.insert(declaration)
            cover(from: declaration)
        }

        return entries
    }

    private func testOnlySuccessors(of declaration: Declaration, in testOnly: Set<Declaration>) -> [Declaration] {
        let referenced = graph.withVariantTwins(declaration).flatMap { source in
            [source.references, source.related].joined()
                .filter { !$0.location.file.isTestFile }
                .compactMap { graph.declaration(withUsr: $0.usr) }
        }
        return (Array(declaration.declarations) + referenced).filter { $0 != declaration && testOnly.contains($0) }
    }

    /// The retained members the compiler generated for the declaration, such as a memberwise initializer, when the full
    /// pass used it: the non-test pass reaches them with the declaration rather than from the roots, so that what
    /// only they reference is not used by the app when only tests use the declaration.
    private func retainedImplicitMembers(of declaration: Declaration) -> [Declaration] {
        declaration.declarations.filter(isRetainedImplicitMemberOfUsedDeclaration)
    }

    private func isRetainedImplicitMemberOfUsedDeclaration(_ declaration: Declaration) -> Bool {
        guard declaration.isImplicit, let parent = declaration.parent else { return false }

        return graph.isUsed(parent) && graph.retainedDeclarations.contains(declaration)
    }

    /// The roots of the non-test pass, outside test files: the retained declarations, but those that only code in test
    /// files keeps (retained members, and the retained implicit members of a used declaration, are reached through their
    /// parent), the declarations
    /// referenced from top-level code, and the declarations named in an `#if` clause, whose branch the index may not
    /// have compiled, with the initializers of the types among them.
    private func nonTestRoots() -> Set<Declaration> {
        let retained = graph.retainedDeclarations.filter {
            !$0.location.file.isTestFile
                && !graph.retainedForTestsOnly.contains($0)
                && !isRetainedImplicitMemberOfUsedDeclaration($0)
        }
        let referenced = graph.rootReferences
            .filter { !$0.location.file.isTestFile }
            .compactMapSet { graph.declaration(withUsr: $0.usr) }
        let names = graph.conditionalCompilationNames
        let conditionallyReferenced = names.isEmpty ? [] : graph.allDeclarations.filter {
            !$0.location.file.isTestFile
                && !PlatformConditionalRetainer.nonReferenceableKinds.contains($0.kind)
                && names.contains(PlatformConditionalRetainer.baseName(of: $0.name))
        }
        // A type named in a clause is usually constructed there (`Client(endpoint:)`), which names no initializer.
        let initializers = conditionallyReferenced.flatMapSet { declaration in
            declaration.declarations.filter { $0.kind == .functionConstructor }
        }
        return retained.union(referenced).union(conditionallyReferenced).union(initializers)
    }

    /// The retained declarations and the declarations referenced from top-level code, sorted so that the recorded
    /// chains do not depend on set order.
    private func rootsWithPredecessors() -> [(Declaration, UsePredecessor)] {
        let retained = graph.retainedDeclarations.sorted().map { ($0, UsePredecessor.retained) }
        let referenced = graph.rootReferences
            .sorted { $0.location < $1.location }
            .compactMap { reference in
                graph.declaration(withUsr: reference.usr).map { ($0, UsePredecessor.rootReference(reference)) }
            }
        return retained + referenced
    }

    /// The same walk as `markUsed(_:)`, breadth-first, recording the predecessor of each declaration so that
    /// `--explain` can print a shortest reference chain from a root. Only used when explanations are recorded.
    private func markUsedRecordingPredecessors(from roots: [(Declaration, UsePredecessor)]) {
        var queue: [Declaration] = []
        var head = 0

        for (declaration, predecessor) in roots {
            graph.recordUsePredecessor(predecessor, for: declaration)
            queue.append(declaration)
        }

        while head < queue.count {
            let declaration = queue[head]
            head += 1
            guard !graph.isUsed(declaration) else { continue }

            graph.markUsed(declaration)

            for source in graph.withVariantTwins(declaration) {
                graph.markUsed(source)

                let references = [source.references, source.related].joined().sorted { $0.location < $1.location }
                for reference in references {
                    if let referenced = graph.declaration(withUsr: reference.usr), !graph.isUsed(referenced) {
                        graph.recordUsePredecessor(.reference(reference, from: source), for: referenced)
                        queue.append(referenced)
                    }
                }
            }
        }
    }

    /// Marks used each `#Preview` expansion and each `PreviewProvider` that previews a used SwiftUI view or widget,
    /// along with the code it references. Previews that only reference unused code stay unused.
    private func markLivePreviewExpansionsUsed(in pass: Pass = .full) {
        var pendingPreviews = graph.references(to: SwiftUIRetainer.previewRegistryUsr)
            .compactMap(\.parent)
            .filter { $0.isImplicit && !isUsed($0, in: pass) }
            .mapSet { $0 }
        pendingPreviews.formUnion(graph.declarations(ofKinds: [.class, .struct, .enum]).filter {
            !isUsed($0, in: pass) && isPreviewProvider($0)
        })

        while true {
            let livePreviews = pendingPreviews.filter { previewsUsedView($0, in: pass) }
            guard !livePreviews.isEmpty else { break }

            pendingPreviews.subtract(livePreviews)
            let previewDeclarations = livePreviews.flatMapSet { $0.descendentDeclarations.union([$0]) }
            if pass == .full {
                previewDeclarations.forEach { graph.recordUsePredecessor(.livePreview, for: $0) }
            }
            markUsed(previewDeclarations, in: pass)
        }
    }

    private func previewsUsedView(_ preview: Declaration, in pass: Pass) -> Bool {
        ([preview] + preview.descendentDeclarations)
            .lazy
            .flatMap(\.references)
            .compactMap { self.graph.declaration(withUsr: $0.usr) }
            .contains { self.isUsed($0, in: pass) && self.isPreviewable($0) }
    }

    /// Whether the type conforms to a previewable protocol (`View`, `Widget` or `ControlWidget`) or subclasses an AppKit
    /// or UIKit view or view controller, directly, through a protocol it conforms to that refines one, or through a
    /// superclass that does.
    private func isPreviewable(_ declaration: Declaration) -> Bool {
        guard [.struct, .class, .enum].contains(declaration.kind) else { return false }

        var visited: Set<Declaration> = [declaration]
        var pending = [declaration]

        while let current = pending.popLast() {
            for related in current.related {
                if related.declarationKind == .protocol, Self.previewableProtocolUsrs.contains(related.usr) {
                    return true
                }

                if related.declarationKind == .class, Self.previewableSuperclassUsrs.contains(related.usr) {
                    return true
                }

                if let inherited = graph.declaration(withUsr: related.usr), visited.insert(inherited).inserted {
                    pending.append(inherited)
                }
            }
        }

        return false
    }

    private func isPreviewProvider(_ declaration: Declaration) -> Bool {
        declaration.related.contains {
            $0.declarationKind == .protocol && $0.usr == Self.previewProviderUsr
        }
    }

    private func ignoreUnusedDescendents(in decls: Set<Declaration>, unusedDeclarations: Set<Declaration>) {
        // With `every_variant`, the variant twins of a declaration share its use, and their own parameters are only
        // reachable from them.
        for decl in decls.flatMap(graph.withVariantTwins) {
            guard !decl.declarations.isEmpty || !decl.unusedParameters.isEmpty
            else { continue }

            if unusedDeclarations.contains(decl) {
                decl.descendentDeclarations.forEach { graph.markIgnored($0) }
            } else {
                ignoreUnusedDescendents(in: decl.declarations,
                                        unusedDeclarations: unusedDeclarations)
            }
        }
    }
}
