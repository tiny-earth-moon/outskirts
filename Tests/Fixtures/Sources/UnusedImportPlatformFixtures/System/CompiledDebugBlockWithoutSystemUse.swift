import Foundation

public func compiledDebugBlockWithoutSystemUse() -> Int {
    #if DEBUG
    return max(1, 2)
    #else
    return 0
    #endif
}
