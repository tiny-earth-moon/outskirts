import Foundation

protocol FixtureQualifiedDescribing {
    func qualifiedDescribe()
}

public enum FixtureQualifiedNamespace {
    protocol Rendering {
        func qualifiedRender()
    }
}

public struct FixtureQualifiedOuter {
    public struct Inner {
        func qualifiedDescribe() {}
        func qualifiedRender() {}
        func qualifiedUnused() {}
    }
}

#if os(iOS)
extension FixtureQualifiedOuter.Inner: FixtureQualifiedDescribing, FixtureQualifiedNamespace.Rendering {}
#endif
