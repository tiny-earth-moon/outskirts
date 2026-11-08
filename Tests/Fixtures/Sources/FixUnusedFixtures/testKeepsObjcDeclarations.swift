#if canImport(ObjectiveC)
    import Foundation

    public final class FixUnusedObjcHolder: NSObject {
        @objc func unusedObjc() {}
    }
#endif
