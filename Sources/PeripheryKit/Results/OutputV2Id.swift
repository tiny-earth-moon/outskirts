import Configuration
import Foundation
import SourceGraph

/// The stable id of an output v2 result: `p2_` followed by the base32 SHA-256 of the rule and an identity that holds
/// neither an absolute path nor a line number, so that it survives an edit above the declaration and another checkout.
enum OutputV2Id {
    static let prefix = "p2_"

    /// The id of a result, whose identity is its sorted USRs. The USRs the analysis makes up for an import, an empty
    /// extension, a String Catalog key or a parameter hold no position: the module and the root-relative file (with
    /// an ordinal when a file has several), the catalog and the key, or the function USR and the parameter name.
    static func id(of result: ScanResult) -> String {
        id(rule: result.rule, identity: result.declaration.usrs.sorted())
    }

    /// The id of a redundant conformance: the USR of the protocol and the USRs of the conforming type, which the
    /// analysis always records with the conformance.
    static func id(ofConformance reference: Reference) -> String {
        id(rule: .redundantConformance, identity: [reference.usr] + (reference.parent?.usrs.sorted() ?? []))
    }

    static func id(rule: RuleIdentifier, identity: [String]) -> String {
        let input = ([rule.rawValue] + identity).joined(separator: "\0")
        return prefix + base32(SHA256.digest(of: Data(input.utf8)))
    }

    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    /// RFC 4648 base32, lowercase and without padding.
    static func base32(_ bytes: [UInt8]) -> String {
        var encoded = ""
        var buffer: UInt32 = 0
        var bitCount = 0

        for byte in bytes {
            buffer = (buffer << 8) | UInt32(byte)
            bitCount += 8

            while bitCount >= 5 {
                encoded.append(alphabet[Int((buffer >> UInt32(bitCount - 5)) & 31)])
                bitCount -= 5
            }
        }

        if bitCount > 0 {
            encoded.append(alphabet[Int((buffer << UInt32(5 - bitCount)) & 31)])
        }

        return encoded
    }
}
