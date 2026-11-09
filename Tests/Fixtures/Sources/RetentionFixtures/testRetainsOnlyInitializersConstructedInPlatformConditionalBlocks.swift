import Foundation

struct FixtureNamedOnlyCamera {
    init() {}
    init(fieldOfView _: Double) {}
    subscript(index: Int) -> Int { index }
    func callAsFunction() {}
    var zoom: Int { 0 }
}

struct FixtureLabeledCamera {
    init(fieldOfView _: Double, aspect _: Double = 1) {}
    init(label _: String) {}
}

struct FixtureTypedCamera {
    init(label _: String) {}
    init(fieldOfView _: Double) {}
}

struct FixtureMetatypeCamera {
    init(label _: String) {}
    init(fieldOfView _: Double) {}
}

func fixtureMakeCamera(_ type: (some Any).Type) -> String {
    String(describing: type)
}

public func fixtureConstructedCameraEntry() {
    _ = FixtureNamedOnlyCamera()
    _ = FixtureLabeledCamera.self
    _ = FixtureTypedCamera.self
    _ = FixtureMetatypeCamera.self
    #if os(iOS)
    let camera: FixtureNamedOnlyCamera? = nil
    _ = camera?.zoom
    _ = FixtureLabeledCamera(fieldOfView: 1)
    let typed: FixtureTypedCamera = .init(label: "")
    _ = typed
    _ = fixtureMakeCamera(FixtureMetatypeCamera.self)
    #endif
}
