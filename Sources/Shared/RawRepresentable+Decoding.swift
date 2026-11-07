public extension RawRepresentable where Self: CaseIterable, RawValue == String {
    /// Decodes the value from its raw value, an invalid one being reported with the accepted values.
    static func decodeRawValue(from decoder: Decoder) throws -> Self {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        guard let value = Self(rawValue: rawValue) else {
            let accepted = allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "expected one of \(accepted), got '\(rawValue)'")
        }

        return value
    }
}
