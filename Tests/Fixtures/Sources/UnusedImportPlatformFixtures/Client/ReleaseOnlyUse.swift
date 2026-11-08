import UnusedImportPlatformSupportFixtures

public func releaseOnlyUse() -> Int {
    #if !DEBUG
    return releaseOnlyHelper()
    #else
    return 0
    #endif
}
