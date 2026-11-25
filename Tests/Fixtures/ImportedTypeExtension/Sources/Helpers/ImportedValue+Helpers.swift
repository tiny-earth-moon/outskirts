@testable import Model

extension ImportedValue: @retroactive CustomDebugStringConvertible {
    public enum Style {
        case plain
    }

    public static func makeImportedValue(style _: Style = .plain) -> Self { Self() }

    public static func makeTestableValue() -> Self { Self() }

    public var debugDescription: String { "ImportedValue" }
}
