func fixUnusedReleaseOnly() {}

func fixUnusedFlagOnly() {}

func fixUnusedNotConditional() {}

public func fixUnusedConditionalUser() {
    #if !DEBUG
        fixUnusedReleaseOnly()
    #endif
    #if FIX_UNUSED_FLAG
        fixUnusedFlagOnly()
    #endif
}
