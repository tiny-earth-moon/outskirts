import Configuration
import FilenameMatcher
import Foundation
import SourceGraph
import SystemPackage

class Indexer {
    private let configuration: Configuration

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    final func filterIndexExcluded(from files: Set<FilePath>) -> (included: Set<FilePath>, excluded: Set<FilePath>) {
        guard !configuration.indexExclude.isEmpty else { return (files, []) }

        let included = files.filter { !configuration.isIndexExcluded($0) }
        return (included, files.subtracting(included))
    }

    /// Whether every declaration of the file is retained, by `retain_files` or an override with `retain.all`.
    final func isRetained(_ file: SourceFile) -> Bool {
        configuration.retainFilesMatchers.anyMatch(filename: file.path.string)
            || (!configuration.overrides.isEmpty && configuration.settings(forModules: file.modules, path: file.path).retainsAll)
    }
}
