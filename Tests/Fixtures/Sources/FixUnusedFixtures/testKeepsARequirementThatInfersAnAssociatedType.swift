protocol FixUnusedInferredConfigurable {
    associatedtype Options
    static func defaults() -> Options
}

struct FixUnusedInferredServer: FixUnusedInferredConfigurable {
    static func defaults() -> Int { 8080 }
}

func fixUnusedInferredOptionsType<T: FixUnusedInferredConfigurable>(_: T.Type) -> Any.Type {
    T.Options.self
}

public func fixUnusedInferredOptions() -> Any.Type {
    fixUnusedInferredOptionsType(FixUnusedInferredServer.self)
}
