import Configuration
import Foundation
import Logger
@testable import ProjectDrivers
import Shared
import SystemPackage
import TestShared
import XCTest

final class GenericProjectDriverTest: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try makeTemporaryDirectory("periphery-generic-config")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testMinimalConfigWithOnlyIndexstores() throws {
        let file = try write(#"{"indexstores": [".build/out"]}"#)

        XCTAssertNoThrow(try GenericProjectDriver(genericProjectConfig: file, configuration: Configuration()))

        let config = try GenericProjectDriver.GenericConfig.load(from: file)
        XCTAssertEqual(config.indexstores, [".build/out"])
        XCTAssertEqual(config.plists, [])
        XCTAssertEqual(config.xibs, [])
        XCTAssertEqual(config.xcdatamodels, [])
        XCTAssertEqual(config.xcmappingmodels, [])
        XCTAssertEqual(config.xcstrings, [])
        XCTAssertEqual(config.testTargets, [])
    }

    func testFullConfigFromTheReadme() throws {
        let file = try write("""
        {
            "indexstores": ["path/to/file.indexstore"],
            "test_targets": ["MyTests"],
            "plists": ["path/to/file.plist"],
            "xibs": ["path/to/file.xib", "path/to/file.storyboard"],
            "xcdatamodels": ["path/to/file.xcdatamodel"],
            "xcmappingmodels": ["path/to/file.xcmappingmodel"],
            "xcstrings": ["path/to/Localizable.xcstrings"]
        }
        """)

        XCTAssertNoThrow(try GenericProjectDriver(genericProjectConfig: file, configuration: Configuration()))

        let config = try GenericProjectDriver.GenericConfig.load(from: file)
        XCTAssertEqual(config.indexstores, ["path/to/file.indexstore"])
        XCTAssertEqual(config.testTargets, ["MyTests"])
        XCTAssertEqual(config.plists, ["path/to/file.plist"])
        XCTAssertEqual(config.xibs, ["path/to/file.xib", "path/to/file.storyboard"])
        XCTAssertEqual(config.xcdatamodels, ["path/to/file.xcdatamodel"])
        XCTAssertEqual(config.xcmappingmodels, ["path/to/file.xcmappingmodel"])
        XCTAssertEqual(config.xcstrings, ["path/to/Localizable.xcstrings"])
    }

    func testMalformedConfigFailsWithAReadableMessage() throws {
        let file = try write(#"{"plists": ["a.plist"]}"#)

        XCTAssertThrowsError(try GenericProjectDriver(genericProjectConfig: file, configuration: Configuration())) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Invalid generic project config \(file.string): missing key 'indexstores'"
            )
        }
    }

    func testEmptyIndexstoresFailsWithAReadableMessage() throws {
        let file = try write(#"{"indexstores": []}"#)

        XCTAssertEqual(message(of: file), "Invalid generic project config \(file.string): 'indexstores' must list at least one index store")
    }

    func testWrongTypeNamesTheKeyAsSpeltInTheFile() throws {
        let plists = try write(#"{"indexstores": ["a"], "plists": "a.plist"}"#)
        let targets = try write(#"{"indexstores": ["a"], "test_targets": [1]}"#)

        XCTAssertEqual(message(of: plists), "Invalid generic project config \(plists.string): 'plists' must be a list")
        XCTAssertEqual(message(of: targets), "Invalid generic project config \(targets.string): 'test_targets[0]' must be a string")
    }

    func testNonObjectAndInvalidJsonFailWithAReadableMessage() throws {
        let list = try write(#"["a"]"#)
        let invalid = try write("{indexstores")

        XCTAssertEqual(message(of: list), "Invalid generic project config \(list.string): the top level must be a JSON object")
        XCTAssertTrue(message(of: invalid).hasPrefix("Invalid generic project config \(invalid.string): "))
        XCTAssertFalse(message(of: invalid).contains("DecodingError"))
    }

    func testMissingFileIsReported() {
        let file = FilePath(directory.appendingPathComponent("missing.json").path)

        XCTAssertThrowsError(try GenericProjectDriver(genericProjectConfig: file, configuration: Configuration())) { error in
            guard case PeripheryError.pathDoesNotExist = error else { return XCTFail("Unexpected error \(error)") }
        }
    }

    func testMissingListedFileNamesTheKeyAndPath() throws {
        let present = try writeFile("", named: "present.xib", in: directory)
        let missing = FilePath(directory.appendingPathComponent("nope.plist").path)
        let file = try write(#"{"indexstores": ["a"], "plists": ["\#(missing.string)"], "xibs": ["\#(present.string)"]}"#)
        let driver = try GenericProjectDriver(genericProjectConfig: file, configuration: Configuration())

        XCTAssertThrowsError(try driver.validateListedFiles()) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Invalid generic project config \(file.string): 'plists' lists '\(missing.string)', which does not exist"
            )
        }
    }

    func testEveryResourceListIsChecked() throws {
        for key in ["xibs", "xcdatamodels", "xcmappingmodels", "xcstrings"] {
            let missing = FilePath(directory.appendingPathComponent("absent-\(key)").path)
            let file = try write(#"{"indexstores": ["a"], "\#(key)": ["\#(missing.string)"]}"#)
            let driver = try GenericProjectDriver(genericProjectConfig: file, configuration: Configuration())

            XCTAssertThrowsError(try driver.validateListedFiles()) { error in
                XCTAssertTrue(error.localizedDescription.contains("'\(key)' lists '\(missing.string)'"), error.localizedDescription)
            }
        }
    }

    #if os(macOS)
        func testPlanCarriesTheConfiguredIndexStores_doesNotRegress() throws {
            let store = directory.appendingPathComponent("store")
            let source = try writeFile("let value = 1\n", named: "main.swift", in: directory)
            let swiftc = Process()
            swiftc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            swiftc.arguments = ["swiftc", "-c", source.string, "-o", directory.appendingPathComponent("main.o").path, "-index-store-path", store.path]
            try swiftc.run()
            swiftc.waitUntilExit()
            XCTAssertEqual(swiftc.terminationStatus, 0)
            let file = try write(#"{"indexstores": ["\#(store.path)"]}"#)
            let driver = try GenericProjectDriver(genericProjectConfig: file, configuration: Configuration())

            let plan = try driver.plan(logger: Logger(quiet: true, verbose: false, colorMode: .never).contextualized(with: "test"))

            XCTAssertEqual(plan.indexStorePaths, [FilePath(store.path)])
        }

        func testTestTargetSources_areMarkedAsTestFiles() throws {
            let store = directory.appendingPathComponent("store")
            let app = try writeFile("let app = 1\n", named: "App.swift", in: directory)
            let shared = try writeFile("let shared = 1\n", named: "Shared.swift", in: directory)
            let tests = try writeFile("let tests = 1\n", named: "AppTests.swift", in: directory)
            try compile([app, shared], module: "App", store: store)
            try compile([tests, shared], module: "AppTests", store: store)
            let file = try write(#"{"indexstores": ["\#(store.path)"], "test_targets": ["AppTests"]}"#)
            let driver = try GenericProjectDriver(genericProjectConfig: file, configuration: Configuration())

            let plan = try driver.plan(logger: Logger(quiet: true, verbose: false, colorMode: .never).contextualized(with: "test"))
            let isTestFile = Dictionary(uniqueKeysWithValues: plan.sourceFiles.keys.map { ($0.path.lastComponent?.string, $0.isTestFile) })

            XCTAssertEqual(isTestFile, ["App.swift": false, "Shared.swift": false, "AppTests.swift": true])
        }
    #endif

    // MARK: - Private

    #if os(macOS)
        private func compile(_ sources: [FilePath], module: String, store: URL) throws {
            let output = directory.appendingPathComponent(module)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let swiftc = Process()
            swiftc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            swiftc.arguments = ["swiftc", "-c", "-parse-as-library", "-module-name", module, "-index-store-path", store.path] + sources.map(\.string)
            swiftc.currentDirectoryURL = output
            try swiftc.run()
            swiftc.waitUntilExit()
            XCTAssertEqual(swiftc.terminationStatus, 0)
        }
    #endif

    private func message(of file: FilePath) -> String {
        do {
            _ = try GenericProjectDriver.GenericConfig.load(from: file)
        } catch {
            return error.localizedDescription
        }

        XCTFail("The config unexpectedly loaded")
        return ""
    }

    private func write(_ json: String) throws -> FilePath {
        try writeFile(json, named: "config-\(UUID().uuidString).json", in: directory)
    }
}
