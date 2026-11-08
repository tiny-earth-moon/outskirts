public struct DeclarationAttribute: Hashable, Sendable, CustomStringConvertible {
    let name: String
    let arguments: String?

    public init(name: String, arguments: String?) {
        self.name = name
        self.arguments = arguments
    }

    /// Marks a Metal function attributed with `[[stitchable]]` or `[[visible]]`, which a client of the library may
    /// look up by name.
    public static let metalExported = DeclarationAttribute(name: "metal_exported", arguments: nil)

    public var description: String {
        if let arguments {
            "\(name)(\(arguments))"
        } else {
            name
        }
    }
}

extension DeclarationAttribute: Comparable {
    public static func < (lhs: DeclarationAttribute, rhs: DeclarationAttribute) -> Bool {
        (lhs.name, lhs.description) < (rhs.name, rhs.description)
    }
}
