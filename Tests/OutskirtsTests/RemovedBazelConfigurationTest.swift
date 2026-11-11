import Configuration
import Foundation
import Shared
import SystemPackage
import TestShared
import XCTest

final class RemovedBazelConfigurationTest: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try makeTemporaryDirectory("periphery-removed-bazel")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testBazelKeysAreRejected() throws {
        for key in ["bazel", "bazel_filter", "bazel_query", "bazel_index_store", "bazel_check_visibility"] {
            let file = try write("\(key): true\n")

            XCTAssertThrowsError(try Configuration().load(from: file) { _ in }, key) { error in
                XCTAssertEqual(
                    error.localizedDescription,
                    "'\(key)' in \(file.string) is no longer supported: Bazel support was removed in 3.13.0. The agoodkind/periphery fork maintains a Bazel mode."
                )
            }
        }
    }

    func testBazelKeyIsRejectedWhateverItsValue() throws {
        let file = try write("bazel: false\n")

        XCTAssertThrowsError(try Configuration().load(from: file) { _ in }) { error in
            guard case PeripheryError.removedBazelOption = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testBazelKeyIsRejectedAmongValidKeys() throws {
        let file = try write("""
        strict: true
        bazel: true
        retain_public: true
        """)

        XCTAssertThrowsError(try Configuration().load(from: file) { _ in }) { error in
            guard case PeripheryError.removedBazelOption = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testOtherKeysStillLoad() throws {
        let configuration = Configuration()
        var warnings: [String] = []
        try configuration.load(from: write("strict: true\nunknown_option: 1\n")) { warnings.append($0) }

        XCTAssertTrue(configuration.strict)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings.first?.contains("unknown_option") == true, "\(warnings)")
    }

    // MARK: - Private

    private func write(_ yaml: String) throws -> FilePath {
        try writeFile(yaml, named: ".periphery.yml", in: directory)
    }
}
