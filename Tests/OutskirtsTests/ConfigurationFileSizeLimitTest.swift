import Configuration
import Foundation
import Shared
import SystemPackage
import TestShared
import XCTest

final class ConfigurationFileSizeLimitTest: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try makeTemporaryDirectory("periphery-config-size")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testOversizedConfigurationIsRejectedBeforeParsing() throws {
        let size = 1024 * 1024 + 1
        let file = try write(String(repeating: "#", count: size))

        XCTAssertThrowsError(try Configuration().load(from: file) { _ in }) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "\(file.string): the configuration file is \(size) bytes, larger than the 1048576 bytes limit"
            )
        }
    }

    func testConfigurationAtTheLimitIsLoaded() throws {
        let header = "retain_public: true\n"
        let file = try write(header + String(repeating: "#", count: 1024 * 1024 - header.utf8.count))
        let configuration = Configuration()

        try configuration.load(from: file) { _ in }

        XCTAssertTrue(configuration.retainPublic)
    }

    func testConfigurationThatIsNotUTF8IsRejected() throws {
        let url = directory.appendingPathComponent(".periphery.yml")
        try Data([0xFF, 0xFE, 0x00]).write(to: url)
        let file = FilePath(url.path)

        XCTAssertThrowsError(try Configuration().load(from: file) { _ in }) { error in
            XCTAssertEqual(error.localizedDescription, "\(file.string): the configuration file is not valid UTF-8")
        }
    }

    func testNestedAliasesAreRejectedWithinBoundedTimeAndMemory() throws {
        // 480 bytes that expand to about eight million values: 1.3 GB and 11 s before the limit.
        let levels = (1 ... 22).map { "x\($0): &a\($0) [*a\($0 - 1), *a\($0 - 1)]" }
        let file = try write((["a0: &a0 [x]"] + levels).joined(separator: "\n"))
        let footprint = Self.physicalFootprint()
        let start = Date()

        XCTAssertThrowsError(try Configuration().load(from: file) { _ in }) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "\(file.string): the configuration holds more than 100000 values once its YAML aliases are expanded"
            )
        }

        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        if let footprint, let after = Self.physicalFootprint() {
            XCTAssertLessThan(after - footprint, 100 * 1024 * 1024)
        }
    }

    func testOrdinaryAliasesAreLoaded() throws {
        let file = try write("""
        exclude_targets: &shared [Generated]
        retain_unused_imported_modules: *shared
        """)
        let configuration = Configuration()
        var warnings: [String] = []

        try configuration.load(from: file) { warnings.append($0) }

        XCTAssertEqual(warnings, [])
        XCTAssertEqual(configuration.excludeTargets, ["Generated"])
        XCTAssertEqual(configuration.retainUnusedImportedModules, ["Generated"])
    }

    /// The memory footprint of the process, read on Darwin only.
    private static func physicalFootprint() -> Int64? {
        #if canImport(Darwin)
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? Int64(info.phys_footprint) : nil
        #else
            return nil
        #endif
    }

    private func write(_ contents: String) throws -> FilePath {
        try writeFile(contents, named: ".periphery.yml", in: directory)
    }
}
