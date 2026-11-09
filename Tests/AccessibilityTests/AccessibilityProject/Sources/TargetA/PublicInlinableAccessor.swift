import Foundation

public class ClassReferencedFromPublicInlinableProperty {}
public class ClassReferencedFromPublicInlinableGetter {}
public class ClassReferencedFromPublicAlwaysEmitIntoClientFunction {}
public class ClassReferencedFromPublicBackDeployedFunction {}

public struct PublicInlinableAccessorHolder {
    public init() {}

    @inlinable
    public var inlinableProperty: Int {
        _ = ClassReferencedFromPublicInlinableProperty.self
        return 0
    }

    public var inlinableGetterProperty: Int {
        @inlinable get {
            _ = ClassReferencedFromPublicInlinableGetter.self
            return 0
        }
    }
}

@_alwaysEmitIntoClient
public func alwaysEmitIntoClientFunction() {
    _ = ClassReferencedFromPublicAlwaysEmitIntoClientFunction.self
}

@available(macOS 13, *)
@backDeployed(before: macOS 99)
public func backDeployedFunction() {
    _ = ClassReferencedFromPublicBackDeployedFunction.self
}
