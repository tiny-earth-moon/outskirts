public enum ColorOption: String, CaseIterable, Equatable, Sendable {
    case auto
    case always
    case never

    static let `default` = ColorOption.auto
}
