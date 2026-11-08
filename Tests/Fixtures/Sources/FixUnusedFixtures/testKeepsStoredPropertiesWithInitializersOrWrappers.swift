@propertyWrapper
public struct FixUnusedWrapper {
    public var wrappedValue: Int

    public init(wrappedValue: Int) {
        self.wrappedValue = wrappedValue
    }
}

func fixUnusedMakeValue() -> Int {
    1
}

public final class FixUnusedInitializerHolder {
    public init() {}

    var computedInitializer = fixUnusedMakeValue()
    static var staticLiteral = 1
    @FixUnusedWrapper var wrapped = 1
}
