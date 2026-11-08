import SwiftUI

@available(macOS 14, *)
public final class FixtureClass1605 {
    public func makeShaders() -> [Shader] {
        [
            ShaderLibrary.default.fixtureUnusedStitchable(.float(1)),
            ShaderLibrary.bundle(.main).fixtureUnusedVisible(.float(1)),
            Shader(function: ShaderLibrary[dynamicMember: "fixtureUnusedFragment"], arguments: []),
            Shader(function: ShaderFunction(library: .default, name: "fixtureSpecializedVertex"), arguments: []),
        ]
    }
}
