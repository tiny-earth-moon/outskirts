@testable import LayerB

extension RetentionHolderB {
    public func retainedModuleExtensionMember() -> Int { 4 }
}

public func useRetentionHolderB() -> Int { RetentionHolderB().retainedModuleExtensionMember() }
