import Configuration
import Foundation
import SystemPackage
import XCTest

final class BuildVariantsConfigurationTest: XCTestCase {
    func testDefaultIsTheSingleBuild() throws {
        let configuration = Configuration()

        XCTAssertEqual(configuration.variants, .default)
        XCTAssertEqual(try load("strict: true\n").configuration.variants, .default)
        XCTAssertEqual(try load("variants: default\n").configuration.variants, .default)
    }

    func testAutoAndTheListForms() throws {
        XCTAssertEqual(try load("variants: auto\n").configuration.variants, .auto)

        let loaded = try load("""
        variants:
          - arm64-apple-macosx15.0
          - arm64-apple-ios18.0-simulator,sdk=iphonesimulator,configuration=release
          - triple: arm64-apple-tvos18.0-simulator
            sdk: /SDKs/AppleTVSimulator.sdk
            configuration: debug
        """)

        XCTAssertEqual(loaded.warnings, [])
        XCTAssertEqual(loaded.configuration.variants, .explicit([
            BuildVariant(triple: "arm64-apple-macosx15.0"),
            BuildVariant(triple: "arm64-apple-ios18.0-simulator", sdk: "iphonesimulator", configuration: "release"),
            BuildVariant(triple: "arm64-apple-tvos18.0-simulator", sdk: "/SDKs/AppleTVSimulator.sdk", configuration: "debug"),
        ]))
    }

    func testInvalidValuesWarnAndFallBackToDefault() throws {
        for yaml in [
            "variants: []\n",
            "variants: 3\n",
            "variants: [auto, arm64-apple-macosx15.0]\n",
            "variants: [\"arm64-apple-macosx15.0,arch=x\"]\n",
            "variants: [\"arm64-apple-macosx15.0,sdk=\"]\n",
            "variants:\n  - sdk: iphonesimulator\n",
            "variants:\n  - triple: arm64-apple-macosx15.0\n    destination: mac\n",
            "variants:\n  - triple: arm64-apple-macosx15.0\n    sdk: 3\n",
        ] {
            let loaded = try load(yaml)
            XCTAssertEqual(loaded.configuration.variants, .default, yaml)
            XCTAssertEqual(loaded.warnings.count, 1, yaml)
            XCTAssertTrue(loaded.warnings.first?.contains("'variants' expects") == true, "\(yaml): \(loaded.warnings)")
        }
    }

    func testCommandLineForm() throws {
        XCTAssertEqual(try BuildVariants(arguments: ["auto"]), .auto)
        XCTAssertEqual(try BuildVariants(arguments: ["arm64-apple-macosx15.0", "arm64-apple-ios18.0-simulator,configuration=release"]), .explicit([
            BuildVariant(triple: "arm64-apple-macosx15.0"),
            BuildVariant(triple: "arm64-apple-ios18.0-simulator", configuration: "release"),
        ]))
        XCTAssertThrowsError(try BuildVariants(arguments: ["default", "arm64-apple-macosx15.0"])) { error in
            XCTAssertTrue("\(error)".hasPrefix("'--variants' expects"), "\(error)")
        }
        XCTAssertEqual(BuildVariant(triple: "t", sdk: "s", configuration: "c").spec, "t,sdk=s,configuration=c")
    }

    func testVariantsTurnOnAutoRetentionUnlessItIsGiven() throws {
        let configuration = Configuration()
        XCTAssertEqual(configuration.resolvedPlatformConditionalRetention, .allClauses)

        configuration.variants = .auto
        XCTAssertEqual(configuration.resolvedPlatformConditionalRetention, .auto)

        let explicit = try load("variants: auto\nplatform_conditional_retention: all-clauses\n").configuration
        XCTAssertEqual(explicit.resolvedPlatformConditionalRetention, .allClauses)

        explicit.disablePlatformConditionalRetention = true
        XCTAssertEqual(explicit.resolvedPlatformConditionalRetention, .off)

        let commandLine = Configuration()
        commandLine.variants = .auto
        commandLine.apply(\.$platformConditionalRetention, .allClauses)
        XCTAssertEqual(commandLine.resolvedPlatformConditionalRetention, .allClauses)
    }

    func testListIsWrittenBackAsYAML() throws {
        let configuration = Configuration()
        configuration.variants = .explicit([BuildVariant(triple: "arm64-apple-ios18.0-simulator", sdk: "iphonesimulator")])

        let yaml = try configuration.asYaml()
        XCTAssertTrue(yaml.contains("variants:\n- triple: arm64-apple-ios18.0-simulator\n  sdk: iphonesimulator\n"), yaml)
    }

    func testSchemaAcceptsTheValidFormsAndRejectsTheOthers() throws {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Configuration().jsonSchema().utf8)) as? [String: Any])
        let validator = JSONSchemaValidator(schema: schema)

        let valid: [Any] = [
            "default",
            "auto",
            ["arm64-apple-ios18.0-simulator,sdk=iphonesimulator,configuration=release"],
            [["triple": "arm64-apple-ios18.0-simulator", "sdk": "iphonesimulator"]],
        ]
        for value in valid {
            XCTAssertEqual(validator.validate(["variants": value]), [], "\(value)")
        }

        let invalid: [Any] = ["all", [], ["x,arch=y"], [["sdk": "iphonesimulator"]], [["triple": "x", "destination": "y"]], 3]
        for value in invalid {
            XCTAssertFalse(validator.validate(["variants": value]).isEmpty, "\(value)")
        }
    }

    // MARK: - Private

    private func load(_ yaml: String) throws -> (configuration: Configuration, warnings: [String]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("outskirts-variants-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".outskirts.yml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        let configuration = Configuration()
        var warnings: [String] = []
        try configuration.load(from: FilePath(file.path)) { warnings.append($0) }
        return (configuration, warnings)
    }
}
