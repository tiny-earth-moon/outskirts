public func packageWideHelper() -> Int { 1 }

public struct PackageScopedValue {
    package let packageToken: Int

    package init(packageToken: Int) {
        self.packageToken = packageToken
    }

    package func packageDescription() -> String { "\(packageToken)" }
}

package struct PackageOnlyValue {
    package init() {}

    public func publicMemberOfPackageType() -> Int { publicMemberOfPackageTypeUsedInModule() - 1 }

    public func publicMemberOfPackageTypeUsedInModule() -> Int { 3 }
}

extension PackageOnlyValue {
    public func publicExtensionMemberOfPackageType() -> Int { 4 }
}

public enum PackageScopeNamespace {
    package struct NestedPackageValue {
        package init() {}

        public func publicMemberOfNestedPackageType() -> Int { 5 }
    }
}
