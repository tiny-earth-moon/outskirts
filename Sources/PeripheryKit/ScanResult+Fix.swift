import SystemPackage

public extension ScanResult {
    /// The catalog and the key of an unused String Catalog key, the only result `outskirts fix` removes.
    var unusedLocalizedStringKey: (catalog: FilePath, key: String)? {
        guard declaration.kind == .localizedString, case .unused = annotation else { return nil }

        return (declaration.location.file.path, declaration.name)
    }
}
