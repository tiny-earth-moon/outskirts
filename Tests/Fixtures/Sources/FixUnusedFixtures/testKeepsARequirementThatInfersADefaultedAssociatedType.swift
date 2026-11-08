protocol FixUnusedDefaultedConfigurable {
    associatedtype Options = [String]
    static func defaults() -> Options
}

struct FixUnusedDefaultedServer: FixUnusedDefaultedConfigurable {
    static func defaults() -> Int { 8080 }
}

func fixUnusedDefaultedOptionsType<T: FixUnusedDefaultedConfigurable>(_: T.Type) -> Any.Type {
    T.Options.self
}

public func fixUnusedDefaultedOptions() -> Any.Type {
    fixUnusedDefaultedOptionsType(FixUnusedDefaultedServer.self)
}
