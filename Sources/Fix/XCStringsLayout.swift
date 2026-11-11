/// Where each member of the top-level `strings` object of a String Catalog lies in its bytes. The bytes are checked
/// against the JSON grammar on the way, so that the gaps between two members hold only whitespace and one comma.
struct XCStringsLayout {
    struct Member {
        /// The key, decoded with every JSON escape, as `XCStringsParser` reads it.
        let key: String
        /// From the opening quote of the key to the end of the value.
        let range: Range<Int>
    }

    /// The offset just after the `{` of the `strings` object.
    let interiorStart: Int
    /// The offset of the `}` of the `strings` object.
    let interiorEnd: Int
    let members: [Member]

    /// Nil when the catalog has no `strings` member.
    static func scan(_ bytes: [UInt8]) throws -> XCStringsLayout? {
        var scanner = JSONScanner(bytes: bytes)
        let layout = try scanner.scanCatalog()
        scanner.skipWhitespace()
        guard scanner.isAtEnd else { throw XCStringsKeyRemovalError.malformedJSON(offset: scanner.offset) }

        return layout
    }
}

/// A strict reader of the JSON grammar (RFC 8259) over bytes, which records the members of the catalog's
/// `strings` object.
private struct JSONScanner {
    private static let maximumDepth = 512

    let bytes: [UInt8]
    private(set) var offset = 0

    var isAtEnd: Bool {
        offset == bytes.count
    }

    mutating func scanCatalog() throws -> XCStringsLayout? {
        skipWhitespace()
        guard peek() == UInt8(ascii: "{") else { throw XCStringsKeyRemovalError.unexpectedStructure("the catalog is not a JSON object") }

        var layout: XCStringsLayout?
        try scanObject(depth: 1) { scanner, key, _ in
            guard key == "strings" else { return try scanner.scanValue(depth: 2) }
            guard scanner.peek() == UInt8(ascii: "{") else {
                throw XCStringsKeyRemovalError.unexpectedStructure("the strings member is not a JSON object")
            }

            layout = try scanner.scanStrings()
        }
        return layout
    }

    mutating func skipWhitespace() {
        while let byte = peek(), [0x20, 0x09, 0x0A, 0x0D].contains(byte) {
            offset += 1
        }
    }

    // MARK: - Private

    private func peek() -> UInt8? {
        offset < bytes.count ? bytes[offset] : nil
    }

    private func malformed() -> XCStringsKeyRemovalError {
        .malformedJSON(offset: offset)
    }

    private mutating func expect(_ character: Unicode.Scalar) throws {
        guard peek() == UInt8(ascii: character) else { throw malformed() }

        offset += 1
    }

    private mutating func scanStrings() throws -> XCStringsLayout {
        let interiorStart = offset + 1
        var members: [XCStringsLayout.Member] = []
        try scanObject(depth: 2) { scanner, key, keyStart in
            try scanner.scanValue(depth: 3)
            members.append(.init(key: key, range: keyStart ..< scanner.offset))
        }
        return XCStringsLayout(interiorStart: interiorStart, interiorEnd: offset - 1, members: members)
    }

    /// Calls `member` with the scanner on the first byte of each value, and refuses a key written twice: JSON readers
    /// keep one of them, not always the same one.
    private mutating func scanObject(depth: Int, member: (inout JSONScanner, String, Int) throws -> Void) throws {
        guard depth <= Self.maximumDepth else { throw XCStringsKeyRemovalError.unexpectedStructure("nested too deeply") }

        try expect("{")
        skipWhitespace()
        if peek() == UInt8(ascii: "}") {
            offset += 1
            return
        }

        var keys = Set<String>()
        while true {
            skipWhitespace()
            let keyStart = offset
            let key = try scanString()
            guard keys.insert(key).inserted else { throw XCStringsKeyRemovalError.duplicateKey(key) }

            skipWhitespace()
            try expect(":")
            skipWhitespace()
            try member(&self, key, keyStart)
            skipWhitespace()
            if peek() == UInt8(ascii: ",") {
                offset += 1
                continue
            }
            try expect("}")
            return
        }
    }

    private mutating func scanArray(depth: Int) throws {
        guard depth <= Self.maximumDepth else { throw XCStringsKeyRemovalError.unexpectedStructure("nested too deeply") }

        try expect("[")
        skipWhitespace()
        if peek() == UInt8(ascii: "]") {
            offset += 1
            return
        }

        while true {
            skipWhitespace()
            try scanValue(depth: depth + 1)
            skipWhitespace()
            if peek() == UInt8(ascii: ",") {
                offset += 1
                continue
            }
            try expect("]")
            return
        }
    }

    private mutating func scanValue(depth: Int) throws {
        switch peek() {
        case UInt8(ascii: "{"): try scanObject(depth: depth) { scanner, _, _ in try scanner.scanValue(depth: depth + 1) }
        case UInt8(ascii: "["): try scanArray(depth: depth)
        case UInt8(ascii: "\""): _ = try scanString()
        case UInt8(ascii: "t"): try scanLiteral("true")
        case UInt8(ascii: "f"): try scanLiteral("false")
        case UInt8(ascii: "n"): try scanLiteral("null")
        default: try scanNumber()
        }
    }

    private mutating func scanLiteral(_ literal: String) throws {
        for byte in literal.utf8 {
            guard peek() == byte else { throw malformed() }

            offset += 1
        }
    }

    private mutating func scanDigits() throws {
        guard let byte = peek(), (0x30 ... 0x39).contains(byte) else { throw malformed() }

        while let byte = peek(), (0x30 ... 0x39).contains(byte) {
            offset += 1
        }
    }

    private mutating func scanNumber() throws {
        if peek() == UInt8(ascii: "-") {
            offset += 1
        }
        if peek() == UInt8(ascii: "0") {
            offset += 1
        } else {
            try scanDigits()
        }
        if peek() == UInt8(ascii: ".") {
            offset += 1
            try scanDigits()
        }
        if peek() == UInt8(ascii: "e") || peek() == UInt8(ascii: "E") {
            offset += 1
            if peek() == UInt8(ascii: "+") || peek() == UInt8(ascii: "-") {
                offset += 1
            }
            try scanDigits()
        }
    }

    /// Decodes a string with every escape; invalid UTF-8, a control character or a lone surrogate is refused.
    private mutating func scanString() throws -> String {
        try expect("\"")
        var utf8: [UInt8] = []
        while true {
            guard let byte = peek() else { throw malformed() }

            offset += 1
            switch byte {
            case UInt8(ascii: "\""):
                guard let string = String(validating: utf8, as: UTF8.self) else { throw malformed() }

                return string
            case UInt8(ascii: "\\"):
                try utf8.append(contentsOf: scanEscape())
            case 0x00 ..< 0x20:
                offset -= 1
                throw malformed()
            default:
                utf8.append(byte)
            }
        }
    }

    private mutating func scanEscape() throws -> [UInt8] {
        guard let byte = peek() else { throw malformed() }

        offset += 1
        switch byte {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): return [byte]
        case UInt8(ascii: "b"): return [0x08]
        case UInt8(ascii: "f"): return [0x0C]
        case UInt8(ascii: "n"): return [0x0A]
        case UInt8(ascii: "r"): return [0x0D]
        case UInt8(ascii: "t"): return [0x09]
        case UInt8(ascii: "u"): return try Array(String(scanUnicodeEscape()).utf8)
        default:
            offset -= 1
            throw malformed()
        }
    }

    /// The scalar of a `\uXXXX` escape whose `\u` was read, joining a high surrogate with the low one that must follow.
    private mutating func scanUnicodeEscape() throws -> Unicode.Scalar {
        let unit = try scanHexUnit()
        if UTF16.isTrailSurrogate(unit) {
            throw malformed()
        }
        guard UTF16.isLeadSurrogate(unit) else {
            guard let scalar = Unicode.Scalar(unit) else { throw malformed() }

            return scalar
        }

        try expect("\\")
        try expect("u")
        let trail = try scanHexUnit()
        guard UTF16.isTrailSurrogate(trail),
              let scalar = Unicode.Scalar(0x10000 + (UInt32(unit - 0xD800) << 10) + UInt32(trail - 0xDC00))
        else { throw malformed() }

        return scalar
    }

    private mutating func scanHexUnit() throws -> UInt16 {
        guard offset + 4 <= bytes.count,
              let text = String(validating: bytes[offset ..< offset + 4], as: UTF8.self),
              text.allSatisfy(\.isHexDigit),
              let unit = UInt16(text, radix: 16)
        else { throw malformed() }

        offset += 4
        return unit
    }
}
