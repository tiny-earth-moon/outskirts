import LayerA

public func usePackageScope() -> String {
    let value = PackageScopedValue(packageToken: packageWideHelper())
    let packageOnlyValue = PackageOnlyValue()
    let nestedValue = PackageScopeNamespace.NestedPackageValue()
    return value.packageDescription()
        + "\(packageOnlyValue.publicMemberOfPackageType())"
        + "\(packageOnlyValue.publicExtensionMemberOfPackageType())"
        + "\(nestedValue.publicMemberOfNestedPackageType())"
}
