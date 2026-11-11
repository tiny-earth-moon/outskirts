import Foundation

/// Removes keys from a String Catalog by cutting their members out of its bytes: every other byte is kept, the JSON
/// is never written again, so the catalog keeps the layout Xcode gave it.
enum XCStringsKeyRemover {
    /// The catalog without the members of `keys` in its top-level `strings` object. Throws an
    /// `XCStringsKeyRemovalError` when a key is missing or written twice, when the bytes are not the expected JSON,
    /// or when the result, read back, is not the original without exactly those keys.
    static func removing(_ keys: Set<String>, from bytes: [UInt8]) throws -> [UInt8] {
        guard !keys.isEmpty else { return bytes }
        guard let layout = try XCStringsLayout.scan(bytes) else { throw XCStringsKeyRemovalError.keysNotFound(keys.sorted()) }

        let missing = keys.subtracting(layout.members.map(\.key))
        guard missing.isEmpty else { throw XCStringsKeyRemovalError.keysNotFound(missing.sorted()) }

        let result = cut(layout.members.indices.filter { keys.contains(layout.members[$0].key) }, from: bytes, layout: layout)
        try verify(result, isOriginal: bytes, without: layout.members.filter { keys.contains($0.key) }.map(\.key))
        return result
    }

    // MARK: - Private

    /// The interior of the `strings` object is `gap₀ member₀ gap₁ member₁ … memberₙ₋₁ gapₙ`, where each inner gap is
    /// whitespace around a comma. A kept member is written after the gap that preceded it, or after `gap₀` when it is
    /// the first one kept, so the comma of a removed member goes with it and the last kept member has none.
    private static func cut(_ removed: [Int], from bytes: [UInt8], layout: XCStringsLayout) -> [UInt8] {
        let members = layout.members
        let removedSet = Set(removed)
        let firstGap = bytes[layout.interiorStart ..< members[0].range.lowerBound]
        let lastGap = bytes[members[members.count - 1].range.upperBound ..< layout.interiorEnd]

        var interior: [UInt8] = []
        var wroteMember = false
        for index in members.indices where !removedSet.contains(index) {
            if wroteMember {
                interior += bytes[members[index - 1].range.upperBound ..< members[index].range.lowerBound]
            } else {
                interior += firstGap
                wroteMember = true
            }
            interior += bytes[members[index].range]
        }
        if wroteMember {
            interior += lastGap
        } else {
            // Xcode writes an empty object as `{`, an empty line, then the indented `}`.
            interior += lineBreak(at: firstGap) + lastGap
        }
        var result = Array(bytes[..<layout.interiorStart])
        result += interior
        result += bytes[layout.interiorEnd...]
        return result
    }

    /// The line break the gap starts with, `\r\n` or `\n`, or nothing.
    private static func lineBreak(at gap: ArraySlice<UInt8>) -> [UInt8] {
        if gap.starts(with: [0x0D, 0x0A]) {
            return [0x0D, 0x0A]
        }
        return gap.first == 0x0A ? [0x0A] : []
    }

    /// Reads both catalogs with `JSONSerialization` and requires the result to be the original without the removed
    /// keys, compared deeply, so that a scanning error can never reach the disk.
    private static func verify(_ result: [UInt8], isOriginal original: [UInt8], without removed: [String]) throws {
        do {
            guard let originalCatalog = try JSONSerialization.jsonObject(with: Data(original)) as? [String: Any],
                  let resultCatalog = try JSONSerialization.jsonObject(with: Data(result)) as? [String: Any],
                  let originalStrings = originalCatalog["strings"] as? [String: Any],
                  let resultStrings = resultCatalog["strings"] as? [String: Any]
            else { throw XCStringsKeyRemovalError.verificationFailed }

            var expectedStrings = originalStrings
            for key in removed {
                expectedStrings.removeValue(forKey: key)
            }
            var expectedCatalog = originalCatalog
            expectedCatalog["strings"] = expectedStrings
            guard expectedStrings.count == originalStrings.count - removed.count,
                  resultStrings.count == expectedStrings.count,
                  try canonicalJSON(resultCatalog) == canonicalJSON(expectedCatalog)
            else { throw XCStringsKeyRemovalError.verificationFailed }
        } catch let error as XCStringsKeyRemovalError {
            throw error
        } catch {
            throw XCStringsKeyRemovalError.verificationFailed
        }
    }

    /// The catalog serialized with sorted keys: equal data means deeply equal catalogs, on every platform.
    private static func canonicalJSON(_ catalog: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys])
    }
}

/// Why a catalog was left as it is.
public enum XCStringsKeyRemovalError: Error, Equatable, Sendable, CustomStringConvertible {
    case malformedJSON(offset: Int)
    case unexpectedStructure(String)
    case duplicateKey(String)
    case keysNotFound([String])
    case verificationFailed

    public var description: String {
        switch self {
        case let .malformedJSON(offset):
            "the catalog is not valid JSON at byte \(offset)"
        case let .unexpectedStructure(reason):
            "unexpected catalog structure: \(reason)"
        case let .duplicateKey(key):
            "the key '\(key)' is written twice"
        case let .keysNotFound(keys):
            "key\(keys.count == 1 ? "" : "s") not found in the catalog: \(keys.map { "'\($0)'" }.joined(separator: ", "))"
        case .verificationFailed:
            "the catalog read back after the removal is not the original without exactly the removed keys"
        }
    }
}
