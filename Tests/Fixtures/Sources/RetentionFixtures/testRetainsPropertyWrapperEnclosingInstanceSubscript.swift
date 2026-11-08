import Foundation

@propertyWrapper struct FixtureEnclosingInstanceWrapper<Value> {
    private var stored: Value

    init(wrappedValue: Value) {
        stored = wrappedValue
    }

    @available(*, unavailable)
    var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }

    static subscript<Instance: AnyObject>(
        _enclosingInstance instance: Instance,
        wrapped _: ReferenceWritableKeyPath<Instance, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<Instance, Self>
    ) -> Value {
        get { instance[keyPath: storageKeyPath].stored }
        set { instance[keyPath: storageKeyPath].stored = newValue }
    }
}

public class FixtureEnclosingInstanceOwner {
    @FixtureEnclosingInstanceWrapper var value = 0

    public func read() -> Int {
        value
    }
}
