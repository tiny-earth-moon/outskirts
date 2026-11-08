func conditionalReleaseOnly() {}

func conditionalFlagOnly() {}

func unconditional() {}

public func conditionalUser() {
    #if !DEBUG
        conditionalReleaseOnly()
    #endif
    #if CONDITIONAL_FLAG
        conditionalFlagOnly()
    #endif
}
