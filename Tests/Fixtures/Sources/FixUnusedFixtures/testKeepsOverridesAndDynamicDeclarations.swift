public class FixUnusedBase {
    public init() {}

    func overridden() {}
}

public final class FixUnusedSubclass: FixUnusedBase {
    override func overridden() {}

    dynamic func unusedDynamic() {
        fixUnusedHelperOfDynamic()
    }
}

func fixUnusedHelperOfDynamic() {}
