@testable import Configuration
import Foundation
import Shared
import SystemPackage
@testable import TestShared
import XCTest

/// Periphery 3.8 compatibility contract for `.periphery.yml`: every key 3.8 accepts still loads, with the same type and
/// value, from the file names 3.8 looked up, and an unknown key is still a warning, not an error.
///
/// A failing test here is a 3.x compatibility break that needs a deliberate decision, not a fixture or test update.
final class Periphery38ConfigurationContractTest: XCTestCase {
    private typealias Value = Contract38Value

    private var contract: Contract38ConfigurationKeys!
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        contract = try Periphery38Contract.decode(Contract38ConfigurationKeys.self, from: "configuration.json")
        directory = try makeTemporaryDirectory("periphery-38-configuration").resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testThe38KeysAreAllListed() {
        XCTAssertEqual(contract.keys.count + contract.removedBazelKeys.count, 50)
    }

    func testEveryKeyOf38LoadsFromPeripheryYmlWithItsTypeAndValue() throws {
        let yaml = try String(contentsOf: Periphery38Contract.url("periphery.yml"), encoding: .utf8)
        try yaml.write(to: directory.appendingPathComponent(".periphery.yml"), atomically: true, encoding: .utf8)
        let configuration = Configuration()
        var warnings: [String] = []

        try withCurrentDirectory { try configuration.load(from: nil) { warnings.append($0) } }

        XCTAssertEqual(warnings, [])
        for (key, expected) in contract.keys.sorted(by: { $0.key < $1.key }) {
            guard let setting = configuration.settings.first(where: { $0.key == key }) else {
                XCTFail("the 3.8 key '\(key)' is no longer a setting")
                continue
            }

            XCTAssertTrue(isCompatible(setting.kind, with: expected.type), "'\(key)' changed from \(expected.type) to \(setting.kind)")
            let loaded = value(of: setting.wrappedValue)
            if expected.unordered == true {
                XCTAssertEqual(loaded?.sorted, expected.value.sorted, "'\(key)' did not load its 3.8 value")
            } else {
                XCTAssertEqual(loaded, expected.value, "'\(key)' did not load its 3.8 value")
            }
        }
    }

    func testPeripheryYamlIsStillLookedUp() throws {
        try "strict: true\n".write(to: directory.appendingPathComponent(".periphery.yaml"), atomically: true, encoding: .utf8)
        let configuration = Configuration()

        try withCurrentDirectory { try configuration.load(from: nil) { XCTFail("Unexpected warning \($0)") } }

        XCTAssertTrue(configuration.strict)
    }

    func testUnknownKeyIsStillAWarningAndTheOtherKeysLoad() throws {
        let path = try writeFile("bogus_key: 1\nstrict: true\n", named: ".periphery.yml", in: directory)
        let configuration = Configuration()
        var warnings: [String] = []

        try configuration.load(from: path) { warnings.append($0) }

        XCTAssertEqual(warnings, ["\(path.string): invalid key 'bogus_key'"])
        XCTAssertTrue(configuration.strict)
    }

    /// 3.8 ran the Bazel mode; it was removed in 3.13.0. Its keys fail the load with an explicit
    /// message instead of being reported as unknown.
    func testRemovedBazelKeysOf38FailTheLoadWithTheRemovalMessage() throws {
        for key in contract.removedBazelKeys.keys.sorted() {
            let path = try writeFile("\(key): true\n", named: ".periphery.yml", in: directory)

            XCTAssertThrowsError(try Configuration().load(from: path) { _ in }, key) { error in
                XCTAssertTrue("\(error)".contains("Bazel support was removed in 3.13.0"), "\(key): \(error)")
            }
        }
    }

    // MARK: - Private

    private func isCompatible(_ kind: SettingValueKind, with type: String) -> Bool {
        switch type {
        case "Bool":
            return [.bool, .boolOrStringList].contains(kind)
        case "[String]":
            return [.stringList, .reportExclude].contains(kind)
        case "FilePath?":
            return kind == .path
        case "[FilePath]":
            return kind == .pathList
        case "OutputFormat":
            return accepts(kind, ["xcode", "csv", "json", "checkstyle", "codeclimate", "github-actions", "github-markdown", "gitlab-codequality"])
        case "ColorOption":
            return accepts(kind, ["auto", "always", "never"])
        default:
            XCTFail("no mapping for the 3.8 type \(type)")
            return false
        }
    }

    private func accepts(_ kind: SettingValueKind, _ values: [String]) -> Bool {
        guard case let .enumeration(accepted) = kind else { return false }

        return Set(values).isSubset(of: accepted)
    }

    private func value(of settingValue: Any) -> Value? {
        switch JSONValue(settingValue: settingValue) {
        case let .bool(value):
            return .bool(value)
        case let .string(value):
            return .string(value)
        case let .array(values):
            let strings = values.compactMap { value -> String? in
                guard case let .string(string) = value else { return nil }

                return string
            }
            return strings.count == values.count ? .strings(strings) : nil
        default:
            return nil
        }
    }

    private func withCurrentDirectory(_ body: () throws -> Void) throws {
        let manager = FileManager.default
        let previous = manager.currentDirectoryPath
        XCTAssertTrue(manager.changeCurrentDirectoryPath(directory.path))
        defer { manager.changeCurrentDirectoryPath(previous) }
        try body()
    }
}
