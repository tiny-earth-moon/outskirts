import Foundation
import Logger
import Shared
import SystemPackage
import TestShared
@testable import XcodeSupport
import XCTest

final class XcodebuildArgumentsTest: XCTestCase {
    private final class RecordingShell: Shell, @unchecked Sendable {
        private(set) var commands: [[String]] = []

        func exec(_ args: [String]) throws -> String {
            commands.append(args)
            if args == ["xcodebuild", "-version"] {
                return "Xcode 99.0\nBuild version 99A1"
            }
            return #"{"project": {"schemes": ["My $(Scheme)"]}}"#
        }
    }

    private final class ProjectStub: XcodeProjectlike {
        let path: FilePath
        let targets: Set<XcodeTarget> = []
        let type = "project"
        let sourceRoot: FilePath

        init(path: FilePath) {
            self.path = path
            sourceRoot = path.removingLastComponent()
        }

        func schemes(additionalArguments _: [String]) throws -> Set<String> {
            []
        }
    }

    private var shell: RecordingShell!
    private var xcodebuild: Xcodebuild!

    override func setUp() {
        super.setUp()
        shell = RecordingShell()
        xcodebuild = Xcodebuild(shell: shell, logger: Logger(quiet: true, verbose: false, colorMode: .never), cacheDirectory: TestCacheDirectory.path)
    }

    func testBuildPassesSchemeProjectAndBuildArgumentsAsLiteralArguments() throws {
        let project = ProjectStub(path: "/tmp/My \"App\" $(touch x)/App.xcodeproj")
        let scheme = "My $(Scheme) `id` 'x'"
        let buildArguments = ["-destination", "generic/platform=iOS Simulator", "OTHER_SWIFT_FLAGS=-D A"]

        try xcodebuild.build(project: project, scheme: scheme, allSchemes: [scheme], additionalArguments: buildArguments)

        let derivedDataPath = try xcodebuild.derivedDataPath(for: project, schemes: [scheme], buildArguments: buildArguments).string
        XCTAssertEqual(shell.commands.last, [
            "xcodebuild",
            "-project", "/tmp/My \"App\" $(touch x)/App.xcodeproj",
            "-scheme", scheme,
            "-parallelizeTargets",
            "-derivedDataPath", derivedDataPath,
            "-quiet",
            "build-for-testing",
            "CODE_SIGNING_ALLOWED=NO",
            "ENABLE_BITCODE=NO",
            "DEBUG_INFORMATION_FORMAT=dwarf",
            "COMPILER_INDEX_STORE_ENABLE=YES",
            "INDEX_ENABLE_DATA_STORE=YES",
            "-destination", "generic/platform=iOS Simulator",
            "OTHER_SWIFT_FLAGS=-D A",
        ])
    }

    func testSchemesPassesPathAndListArgumentsAsLiteralArguments() throws {
        let path = "/tmp/it's $(here)/App.xcodeproj"

        let schemes = try xcodebuild.schemes(type: "project", path: path, additionalArguments: ["-skipPackageUpdates", "$(x)"])

        XCTAssertEqual(schemes, ["My $(Scheme)"])
        let command = try XCTUnwrap(shell.commands.last)
        XCTAssertEqual(Array(command.prefix(5)), ["xcodebuild", "-project", path, "-list", "-json"])
        XCTAssertTrue(command[5].hasPrefix("-IDECustomDerivedDataLocation=/"), command[5])
        XCTAssertFalse(command[5].contains("'"), command[5])
        XCTAssertEqual(Array(command.suffix(2)), ["-skipPackageUpdates", "$(x)"])
    }

    func testBuildRefusesBuildArgumentsThatMoveTheDerivedData() throws {
        let project = ProjectStub(path: "/tmp/App/App.xcodeproj")
        let refused: [[String]] = [
            ["-derivedDataPath", "/tmp/elsewhere"],
            ["-DerivedDataPath", "/tmp/elsewhere"],
            ["--derivedDataPath=/tmp/elsewhere"],
            ["-resultBundlePath", "/tmp/r.xcresult"],
            ["-archivePath", "/tmp/a.xcarchive"],
            ["-IDECustomDerivedDataLocation=/tmp/elsewhere"],
        ]

        for arguments in refused {
            XCTAssertThrowsError(try xcodebuild.build(project: project, scheme: "A", allSchemes: ["A"], additionalArguments: ["-quiet"] + arguments)) { error in
                let description = (error as? PeripheryError)?.errorDescription ?? ""
                XCTAssertTrue(description.contains("'build_arguments' cannot contain '\(arguments[0])'"), description)
            }
        }
        XCTAssertFalse(shell.commands.contains { $0.contains("build-for-testing") })
    }

    func testBuildRefusesBuildSettingsThatMoveTheBuildProducts() throws {
        let project = ProjectStub(path: "/tmp/App/App.xcodeproj")
        let refused = [
            "SYMROOT=/tmp/elsewhere",
            "OBJROOT=/tmp/elsewhere",
            "DSTROOT=/tmp/elsewhere",
            "CONFIGURATION_BUILD_DIR=/tmp/elsewhere",
            "symroot=/tmp/elsewhere",
            "SYMROOT[sdk=iphoneos*]=/tmp/elsewhere",
        ]

        for argument in refused {
            XCTAssertThrowsError(try xcodebuild.build(project: project, scheme: "A", allSchemes: ["A"], additionalArguments: [argument])) { error in
                let description = (error as? PeripheryError)?.errorDescription ?? ""
                XCTAssertTrue(description.contains("'build_arguments' cannot contain '\(argument)'"), description)
            }
        }
        XCTAssertFalse(shell.commands.contains { $0.contains("build-for-testing") })
    }

    func testBuildKeepsArgumentsThatDoNotMoveTheBuild() throws {
        let project = ProjectStub(path: "/tmp/App/App.xcodeproj")
        let arguments = [
            "-destination", "platform=macOS",
            "-configuration", "Release",
            "-xcconfig", "Config/CI.xcconfig",
            "OTHER_SWIFT_FLAGS=-D SYMROOT=1",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphoneos*]=DEVICE",
            "SYMROOT_EXTRA=1",
        ]

        try xcodebuild.build(project: project, scheme: "A", allSchemes: ["A"], additionalArguments: arguments)

        let command = try XCTUnwrap(shell.commands.last)
        XCTAssertEqual(Array(command.suffix(arguments.count)), arguments)
        XCTAssertEqual(command.filter { $0 == "-derivedDataPath" }.count, 1)
    }

    func testSchemesRefusesListArgumentsThatMoveTheDerivedData() throws {
        for arguments in [["-IDECustomDerivedDataLocation=/tmp/elsewhere"], ["-clonedSourcePackagesDirPath", "/tmp/elsewhere"]] {
            XCTAssertThrowsError(try xcodebuild.schemes(type: "project", path: "/tmp/App/App.xcodeproj", additionalArguments: arguments)) { error in
                let description = (error as? PeripheryError)?.errorDescription ?? ""
                XCTAssertTrue(description.contains("'xcode_list_arguments' cannot contain '\(arguments[0])'"), description)
            }
        }
        XCTAssertFalse(shell.commands.contains { $0.contains("-list") })
    }

    func testRemoveDerivedDataDeletesTheFolderWithoutAShell() throws {
        let project = ProjectStub(path: FilePath("/tmp/periphery-\(UUID().uuidString)/App.xcodeproj"))
        let path = try xcodebuild.derivedDataPath(for: project, schemes: ["A"])
        try FileManager.default.createDirectory(atPath: path.appending("Index.noindex").string, withIntermediateDirectories: true)

        try xcodebuild.removeDerivedData(for: project, allSchemes: ["A"])

        XCTAssertFalse(FileManager.default.fileExists(atPath: path.string))
        XCTAssertNoThrow(try xcodebuild.removeDerivedData(for: project, allSchemes: ["A"]))
        XCTAssertFalse(shell.commands.contains { $0.first == "rm" })
    }
}
