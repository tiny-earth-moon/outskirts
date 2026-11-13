import Foundation

public extension String {
    @inlinable var trimmed: String {
        trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    @inlinable
    func escapedForXML() -> String {
        // & needs to go first, otherwise other replacements will be replaced again
        let htmlEscapes = [
            ("&", "&amp;"),
            ("\"", "&quot;"),
            ("'", "&apos;"),
            (">", "&gt;"),
            ("<", "&lt;"),
        ]
        var newString = self
        for (key, value) in htmlEscapes {
            newString = newString.replacingOccurrences(of: key, with: value)
        }
        // XML 1.0 forbids the other control characters, and an attribute value turns tabs and line breaks into spaces.
        return newString.withVisibleControlCharacters(replacement: { scalar in
            switch scalar {
            case "\t", "\n", "\r": "&#\(scalar.value);"
            default: nil
            }
        })
    }

    /// Replaces each control character, and each noncharacter U+FFFE or U+FFFF, with a visible escape such as `\n` or
    /// `\u{1}`, so that untrusted text can neither break the structure of a report nor vanish from it.
    func withVisibleControlCharacters(
        keeping keep: (Unicode.Scalar) -> Bool = { _ in false },
        replacement: (Unicode.Scalar) -> String? = { _ in nil }
    ) -> String {
        guard unicodeScalars.contains(where: { $0.isReportControlCharacter && !keep($0) }) else { return self }

        var result = ""
        for scalar in unicodeScalars {
            guard scalar.isReportControlCharacter, !keep(scalar) else {
                result.unicodeScalars.append(scalar)
                continue
            }

            if let replaced = replacement(scalar) {
                result += replaced
                continue
            }

            switch scalar {
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            }
        }
        return result
    }

    /// http://www.cse.yorku.ca/~oz/hash.html
    @inlinable var djb2: Int {
        unicodeScalars
            .map(\.value)
            .reduce(5381) { ($0 << 5) &+ $0 &+ Int($1) }
    }

    @inlinable var djb2Hex: String {
        String(format: "%02x", djb2)
    }
}

public extension Unicode.Scalar {
    var isReportControlCharacter: Bool {
        properties.generalCategory == .control || value == 0xFFFE || value == 0xFFFF
    }
}
