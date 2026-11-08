import UnusedImportPlatformSupportFixtures

public func debugBlockWithoutModuleUse() -> Int {
    #if !DEBUG
    return localDebugHelper()
    #else
    return 0
    #endif
}

func localDebugHelper() -> Int { 6 }
