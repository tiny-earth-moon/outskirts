import Configuration

public extension Configuration {
    /// The settings that apply to the declaration, from its modules and file: the top-level ones changed by the
    /// matching `overrides`.
    func settings(for declaration: Declaration) -> DeclarationSettings {
        settings(forModules: declaration.location.file.modules, path: declaration.location.file.path)
    }
}
