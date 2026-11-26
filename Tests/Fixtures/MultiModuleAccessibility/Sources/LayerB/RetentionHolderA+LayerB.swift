@testable import LayerA

extension RetentionHolderA {
    public func unretainedModuleExtensionMember() -> Int { 5 }
}

public func useRetentionHolderA() -> Int { RetentionHolderA().unretainedModuleExtensionMember() }
