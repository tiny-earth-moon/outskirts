import Foundation

struct FixtureCompiledElseHandle {
    init(descriptor _: Int32) {}
    subscript(index: Int) -> Int { index }
}

struct FixtureCompiledImportBuffer {
    init(capacity _: Int) {}
    subscript(index: Int) -> Int { index }
}

struct FixtureUncompiledImportView {
    init(frame _: Int) {}
    init(coder _: String) {}
}

#if !os(WASI)
public func fixtureCompiledElseEntry() {
    #if os(Windows)
    fatalError()
    #else
    let handle: FixtureCompiledElseHandle? = nil
    let descriptors = [handle]
    _ = descriptors[0]
    #endif
}
#endif

public func fixtureCompiledImportEntry() {
    #if canImport(Dispatch)
    let buffer: FixtureCompiledImportBuffer? = nil
    let buffers = [buffer]
    _ = buffers[0]
    #endif
    #if canImport(UIKit)
    _ = FixtureUncompiledImportView(frame: 0)
    #endif
}
