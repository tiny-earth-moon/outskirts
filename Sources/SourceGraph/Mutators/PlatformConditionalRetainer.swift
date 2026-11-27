import Configuration
import Foundation
import Shared

/// The index store only describes the platform it was built for, so code that is only reachable on another
/// platform appears unused. This retains:
///  - declarations marked `@available(<platform>, unavailable)`, as they exist for other platforms, and
///  - declarations whose name is written inside a platform conditional `#if` block, as the reference may live
///    in a branch that was not compiled. With `report_test_only`, a declaration whose name only test files write is
///    retained for the tests only, so that it can still be reported as test-only.
final class PlatformConditionalRetainer: SourceGraphMutator {
    static let nonReferenceableKinds: Set<Declaration.Kind> = [
        .module, .extension, .extensionClass, .extensionEnum, .extensionProtocol, .extensionStruct,
        .functionConstructor, .functionDestructor, .varParameter, .varLocal, .genericTypeParam,
        .functionAccessorAddress, .functionAccessorDidset, .functionAccessorGetter, .functionAccessorMutableaddress,
        .functionAccessorSetter, .functionAccessorWillset, .functionAccessorRead, .functionAccessorModify,
        .functionAccessorInit,
    ]

    private let graph: SourceGraph
    private let configuration: Configuration

    required init(graph: SourceGraph, configuration: Configuration, swiftVersion _: SwiftVersion) {
        self.graph = graph
        self.configuration = configuration
    }

    func mutate() {
        guard !configuration.disablePlatformConditionalRetention else { return }

        let names = graph.platformConditionalNames
        let namesOutsideTestFiles = configuration.reportTestOnly ? self.namesOutsideTestFiles() : names

        for decl in graph.allDeclarations {
            if isUnavailableOnPlatform(decl) {
                graph.markRetained(decl, reason: RetentionReason(Self.self, "unavailable on a platform, so it exists for the others"))
                graph.markRetained(
                    decl.descendentDeclarations,
                    reason: RetentionReason(Self.self, "within a declaration unavailable on a platform")
                )
            } else if !names.isEmpty,
                      !Self.nonReferenceableKinds.contains(decl.kind),
                      names.contains(Self.baseName(of: decl.name))
            {
                if namesOutsideTestFiles.contains(Self.baseName(of: decl.name)) {
                    graph.markRetained(decl, reason: RetentionReason(Self.self, namingDetail(for: decl)))
                } else {
                    // Only tests name it: the full walk keeps it, the walk from the app does not start from it.
                    graph.markRetainedForTestsOnly(decl, reason: RetentionReason(Self.self, namingDetail(for: decl, onlyTestFiles: true)))
                }
            }
        }
    }

    // MARK: - Private

    private func namesOutsideTestFiles() -> Set<String> {
        graph.platformConditionalNamesByFile
            .filter { !$0.key.isTestFile }
            .reduce(into: Set<String>()) { $0.formUnion($1.value) }
    }

    private func namingDetail(for decl: Declaration, onlyTestFiles: Bool = false) -> String {
        let name = Self.baseName(of: decl.name)
        let files = graph.platformConditionalNamesByFile
            .filter { $0.value.contains(name) }
            .map(\.key.path.string)
            .sorted()
        let detail = "its name is written in a platform conditional `#if` block of \(files.joined(separator: ", "))"
        return onlyTestFiles ? detail + ", only in test files, so the app does not use it through this retention" : detail
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

    private func isUnavailableOnPlatform(_ decl: Declaration) -> Bool {
        decl.attributes.contains { attribute in
            guard attribute.name == "available", let arguments = attribute.arguments else { return false }

            let parts = Self.removingStringLiterals(from: arguments)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            guard let platform = parts.first,
                  platform != "*",
                  platform != "swift",
                  !platform.hasSuffix("ApplicationExtension")
            else { return false }

            return parts.dropFirst().contains("unavailable")
        }
    }
}
