import Foundation
import Logger
import SystemPackage

/// The Swift files that can be removed whole: every top-level declaration, imports excepted, is reported as unused.
struct ScanSummary: Equatable {
    struct UnusedFile: Equatable {
        let path: FilePath
        let lineCount: Int
    }

    /// Sorted by path.
    let unusedFiles: [UnusedFile]
}

struct ScanSummaryBuilder {
    let logger: Logger
    /// The declarations of a Swift file, nil when it cannot be read, for a caller that has already parsed the files;
    /// each file is read and parsed otherwise.
    var declarationsInFile: ((FilePath) -> SourceFileDeclarations?)?

    func build(_ results: [ScanResult]) -> ScanSummary {
        var removedByFile: [FilePath: [ScanResult]] = [:]

        for result in results {
            let file = result.declaration.location.file.path
            if result.annotation.removesCode, file.extension == "swift" {
                removedByFile[file, default: []].append(result)
            }
        }

        var unusedFiles: [ScanSummary.UnusedFile] = []

        for (file, removed) in removedByFile.sorted(by: { $0.key.string < $1.key.string }) {
            guard let declarations = declarations(in: file) else { continue }

            var reportedElements: [Int: Set<Int>] = [:]
            for result in removed {
                let location = result.declaration.location
                let position = SourceFileDeclarations.Position(line: location.line, column: location.column)
                if let (span, element) = declarations.elementsByPosition[position] {
                    reportedElements[span, default: []].insert(element)
                }
            }

            let removedSpans = Set(reportedElements.compactMap { span, elements in
                elements.count == declarations.spans[span].elementCount ? span : nil
            })

            if !declarations.hasOtherTopLevelCode, !declarations.topLevelSpans.isEmpty, declarations.topLevelSpans.allSatisfy(removedSpans.contains) {
                unusedFiles.append(.init(path: file, lineCount: declarations.lineCount))
            }
        }

        return ScanSummary(unusedFiles: unusedFiles)
    }

    // MARK: - Private

    private func declarations(in file: FilePath) -> SourceFileDeclarations? {
        if let declarationsInFile {
            return declarationsInFile(file)
        }

        do {
            return try SourceFileDeclarations(source: String(contentsOfFile: file.string, encoding: .utf8))
        } catch {
            logger.warn("The summary leaves out \(file.string), which could not be read: \(error.localizedDescription)")
            return nil
        }
    }
}

private extension ScanResult.Annotation {
    /// Whether acting on the result deletes code: accessibility, `final` and assign-only results only change it.
    var removesCode: Bool {
        switch self {
        case .unused, .emptyExtension:
            true
        default:
            false
        }
    }
}
