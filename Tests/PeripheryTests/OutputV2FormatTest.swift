import Configuration
import Foundation
import Logger
@testable import PeripheryKit
@testable import SourceGraph
import SystemPackage
@testable import TestShared
import XCTest
import Yams

/// The `json-v2` format: a golden document for results of every rule, validated against `schemas/output-v2.json`,
/// and ids that survive an edit above the declarations and another checkout.
///
/// Set `PERIPHERY_UPDATE_GOLDEN` to rewrite the golden document from the current output.
final class OutputV2FormatTest: XCTestCase {
    private let logger = Logger(quiet: true, verbose: false, colorMode: .never)
    private let projectRoot = "/work/project"

    // MARK: - Golden document

    func testOutput_matchesTheGoldenFile() throws {
        let output = try format(results())
        let url = ProjectRootPath.appending("Tests/Fixtures/Golden/json-v2.json").url

        if ProcessInfo.processInfo.environment["PERIPHERY_UPDATE_GOLDEN"] != nil {
            try Data((output + "\n").utf8).write(to: url)
        }

        XCTAssertEqual(output + "\n", try String(contentsOf: url, encoding: .utf8), "The json-v2 output differs from \(url.path)")
    }

    func testFixture_coversEveryRule() throws {
        let results = try document(format(results()))["results"] as? [[String: Any]] ?? []
        let rules = results.compactMap { $0["rule"] as? String }
            + results.flatMap { $0["related"] as? [[String: Any]] ?? [] }.compactMap { $0["rule"] as? String }

        XCTAssertEqual(Set(rules), Set(RuleIdentifier.allCases.map(\.rawValue)))
    }

    // MARK: - Schema

    func testOutput_validatesAgainstTheSchema() throws {
        let validator = try JSONSchemaValidator(schema: schema())

        XCTAssertEqual(validator.validate(try document(format(results()))), [])
        XCTAssertEqual(validator.validate(try document(format([]))), [])
    }

    func testSchema_rejectsADocumentThatBreaksTheContract() throws {
        let validator = try JSONSchemaValidator(schema: schema())
        let valid = try document(format(results()))

        var missingVersion = valid
        missingVersion["schemaVersion"] = nil
        XCTAssertFalse(validator.validate(missingVersion).isEmpty)

        var unknownRule = valid
        var results = try XCTUnwrap(valid["results"] as? [[String: Any]])
        results[0]["rule"] = "unused-imports"
        unknownRule["results"] = results
        XCTAssertFalse(validator.validate(unknownRule).isEmpty)

        var numericFixable = valid
        results = try XCTUnwrap(valid["results"] as? [[String: Any]])
        results[0]["fixable"] = 1
        numericFixable["results"] = results
        XCTAssertFalse(validator.validate(numericFixable).isEmpty)
    }

    // MARK: - Ids

    func testIds_doNotChangeWhenABlankLineIsInsertedAboveEveryDeclaration() throws {
        let before = try ids(format(results()))
        let after = try ids(format(results(lineOffset: 1)))

        XCTAssertEqual(before.count, 19)
        XCTAssertEqual(Set(before).count, before.count, "Ids must be unique")
        XCTAssertEqual(after, before)
    }

    func testIds_doNotChangeWhenTheCheckoutMoves() throws {
        let moved = "/elsewhere/checkout"
        let before = try document(format(results()))
        let after = try document(format(results(root: moved), root: moved))

        XCTAssertEqual(try ids(format(results(root: moved), root: moved)), try ids(format(results())))
        XCTAssertEqual(paths(after), paths(before))
        XCTAssertEqual((after["run"] as? [String: Any])?["projectRoot"] as? String, moved)
    }

    func testIds_differByRuleForOneDeclaration() {
        let declaration = Declaration(name: "legacy()", kind: .functionFree, usrs: ["s:3Lib6legacyyyF"], location: location("Sources/Lib/Legacy.swift", line: 3, column: 6))

        XCTAssertNotEqual(
            OutputV2Id.id(of: ScanResult(declaration: declaration, annotation: .unused)),
            OutputV2Id.id(of: ScanResult(declaration: declaration, annotation: .superfluousIgnoreCommand))
        )
    }

    func testId_isTheBase32Sha256OfTheRuleAndTheIdentity() {
        XCTAssertEqual(OutputV2Id.base32(Array("".utf8)), "")
        XCTAssertEqual(OutputV2Id.base32(Array("f".utf8)), "my")
        XCTAssertEqual(OutputV2Id.base32(Array("fo".utf8)), "mzxq")
        XCTAssertEqual(OutputV2Id.base32(Array("foo".utf8)), "mzxw6")
        XCTAssertEqual(OutputV2Id.base32(Array("foob".utf8)), "mzxw6yq")
        XCTAssertEqual(OutputV2Id.base32(Array("fooba".utf8)), "mzxw6ytb")
        XCTAssertEqual(OutputV2Id.base32(Array("foobar".utf8)), "mzxw6ytboi")

        let digest = SHA256.digest(of: Data("unused\0s:3Lib6WidgetC".utf8))
        XCTAssertEqual(OutputV2Id.id(rule: .unused, identity: ["s:3Lib6WidgetC"]), "p2_" + OutputV2Id.base32(digest))
    }

    // MARK: - Paths and files

    func testPaths_areRelativeToTheProjectRootWhateverTheRelativeResultsSettingsSay() throws {
        let configuration = Configuration()
        configuration.projectRoot = FilePath(projectRoot)
        configuration.relativeResults = false
        configuration.relativeResultsBase = FilePath("Sources")
        let formatter = JsonV2Formatter(configuration: configuration, logger: logger)

        XCTAssertEqual(paths(try document(XCTUnwrap(formatter.format(results(), colored: false)))), paths(try document(format(results()))))
        XCTAssertTrue(paths(try document(format(results()))).allSatisfy { !$0.hasPrefix("/") })
    }

    func testFiles_holdTheDigestOfEveryFileWithAResult() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OutputV2FormatTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("abc".utf8).write(to: root.appendingPathComponent("Sources/A.swift"))

        let present = Declaration(name: "a", kind: .varGlobal, usrs: ["s:1A1aSivp"], location: Location(file: SourceFile(path: FilePath(root.path + "/Sources/A.swift"), modules: ["A"]), line: 1, column: 5))
        let missing = Declaration(name: "b", kind: .varGlobal, usrs: ["s:1A1bSivp"], location: Location(file: SourceFile(path: FilePath(root.path + "/Sources/B.swift"), modules: ["A"]), line: 1, column: 5))
        let output = try format([ScanResult(declaration: present, annotation: .unused), ScanResult(declaration: missing, annotation: .unused)], root: root.path)
        let files = try XCTUnwrap((document(output)["run"] as? [String: Any])?["files"] as? [String: Any])

        XCTAssertEqual(files["Sources/A.swift"] as? String, "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertTrue(files["Sources/B.swift"] is NSNull)
    }

    // MARK: - Fixture

    private func location(_ path: String, root: String? = nil, modules: Set<String> = ["Lib"], line: Int, column: Int) -> Location {
        Location(file: SourceFile(path: FilePath((root ?? projectRoot) + "/" + path), modules: modules), line: line, column: column)
    }

    private func range(_ start: Int, _ end: Int, endColumn: Int = 2) -> DeclarationRange {
        DeclarationRange(start: SourcePosition(line: start, column: 1), end: SourcePosition(line: end, column: endColumn))
    }

    /// One result of every rule, the conformances of the redundant protocol under `related`, with an unconstructed
    /// enum case and a missing Metal function that count as `unused`. `lineOffset` moves every declaration down.
    private func results(root: String? = nil, lineOffset offset: Int = 0) -> [ScanResult] {
        let root = root ?? projectRoot
        let rootPath = FilePath(root)
        func at(_ path: String, modules: Set<String> = ["Lib"], line: Int, column: Int) -> Location {
            location(path, root: root, modules: modules, line: line + offset, column: column)
        }

        let widget = Declaration(name: "Widget", kind: .class, usrs: ["s:3Lib6WidgetC"], location: at("Sources/Lib/Widget.swift", line: 3, column: 14))
        widget.range = range(3 + offset, 9 + offset)

        let importFile = FilePath(root + "/Sources/Lib/Widget.swift")
        let unusedImport = Declaration(name: "Combine", kind: .module, usrs: [SyntheticUsr.moduleImport("Combine", in: importFile, projectRoot: rootPath)], location: at("Sources/Lib/Widget.swift", line: 1, column: 1))
        unusedImport.range = range(1 + offset, 1 + offset, endColumn: 15)

        let run = Declaration(name: "run(count:)", kind: .functionFree, usrs: ["s:3Lib3run5countySi_tF"], location: at("Sources/Lib/Run.swift", line: 2, column: 6))
        let parameter = Declaration(name: "count", kind: .varParameter, usrs: ["param-count-run(count:)-s:3Lib3run5countySi_tF"], location: at("Sources/Lib/Run.swift", line: 2, column: 10))
        parameter.parent = run

        let catalog = FilePath(root + "/Resources/Localizable.xcstrings")
        let greeting = Declaration(name: "greeting", kind: .localizedString, usrs: [SyntheticUsr.localizedString("greeting", in: catalog, projectRoot: rootPath)], location: at("Resources/Localizable.xcstrings", modules: ["App"], line: 4, column: 5))

        let accent = Declaration(name: "accent", kind: .varStatic, usrs: ["s:So7ColorV3AppE6accentABvpZ"], location: at("DerivedSources/GeneratedAssetSymbols.swift", modules: ["App"], line: 3, column: 16))
        let accentSymbol = AssetCatalogSymbol(kind: .color, assetName: "AccentColor", assetPaths: [FilePath(root + "/App/Assets.xcassets/AccentColor.colorset")])
        let logo = Declaration(name: "logo", kind: .varStatic, usrs: ["s:So5ImageV3AppE4logoABvpZ"], location: at("DerivedSources/GeneratedAssetSymbols.swift", modules: ["App"], line: 7, column: 16))
        let logoSymbol = AssetCatalogSymbol(kind: .image, assetName: nil, assetPaths: [])

        let cache = Declaration(name: "cache", kind: .varInstance, usrs: ["s:3Lib6WidgetC5cacheSDySSSiGvp"], location: at("Sources/Lib/Widget.swift", line: 4, column: 9))
        let delegate = Declaration(name: "delegate", kind: .varInstance, usrs: ["s:3Lib6WidgetC8delegateAA0B8DelegateCSgvp"], location: at("Sources/Lib/Widget.swift", line: 5, column: 9))

        let marker = Declaration(name: "Marker", kind: .protocol, usrs: ["s:3Lib6MarkerP"], location: at("Sources/Lib/Marker.swift", line: 1, column: 10))
        let references = [("Beta", 7), ("Alpha", 3)].map { name, line in
            let type = Declaration(name: name, kind: .struct, usrs: ["s:3Lib\(name.count)\(name)V"], location: at("Sources/Lib/Types.swift", line: line, column: 8))
            let reference = Reference(name: "Marker", kind: .related, declarationKind: .protocol, usr: "s:3Lib6MarkerP", location: at("Sources/Lib/Types.swift", line: line, column: 8 + name.count + 2))
            reference.parent = type
            return reference
        }

        let helper = Declaration(name: "helper()", kind: .functionFree, usrs: ["s:3Lib6helperyyF"], location: at("Sources/Lib/Helper.swift", line: 5, column: 13))
        helper.accessibility = DeclarationAccessibility(value: .public, isExplicit: true)
        helper.range = range(5 + offset, 7 + offset)

        let base = Declaration(name: "Base", kind: .class, usrs: ["s:3Lib4BaseC"], location: at("Sources/Lib/Base.swift", line: 1, column: 12))
        base.accessibility = DeclarationAccessibility(value: .open, isExplicit: true)
        let leaf = Declaration(name: "Leaf", kind: .class, usrs: ["s:3Lib4LeafC"], location: at("Sources/Lib/Leaf.swift", line: 1, column: 7))
        let tag = Declaration(name: "tag", kind: .varGlobal, usrs: ["s:3Lib3tagSSvp"], location: at("Sources/Lib/Tag.swift", line: 1, column: 14))
        tag.accessibility = DeclarationAccessibility(value: .internal, isExplicit: true)

        let extensionFile = FilePath(root + "/Sources/Lib/Widget+Empty.swift")
        let emptyExtension = Declaration(name: "Widget", kind: .extensionClass, usrs: [SyntheticUsr.emptyExtension(of: "Widget", in: extensionFile, projectRoot: rootPath)], location: at("Sources/Lib/Widget+Empty.swift", line: 1, column: 11))

        let legacy = Declaration(name: "legacy()", kind: .functionFree, usrs: ["s:3Lib6legacyyyF"], location: at("Sources/Lib/Legacy.swift", line: 2, column: 6))
        let retrying = Declaration(name: "retrying", kind: .enumelement, usrs: ["s:3Lib5StateO8retryingyA2CmF"], location: at("Sources/Lib/State.swift", line: 4, column: 10))
        let shaderFile = FilePath(root + "/Sources/Lib/Renderer.swift")
        let blurr = Declaration(name: "blurr", kind: .metalFunction, usrs: [SyntheticUsr.missingMetalFunction("blurr", in: shaderFile, projectRoot: rootPath)], location: at("Sources/Lib/Renderer.swift", line: 12, column: 40))

        return [
            ScanResult(declaration: widget, annotation: .unused),
            ScanResult(declaration: unusedImport, annotation: .unused),
            ScanResult(declaration: parameter, annotation: .unused),
            ScanResult(declaration: greeting, annotation: .unused),
            ScanResult(declaration: accent, annotation: .unusedAssetCatalogSymbol(accentSymbol)),
            ScanResult(declaration: logo, annotation: .unusedAssetCatalogSymbol(logoSymbol)),
            ScanResult(declaration: cache, annotation: .assignOnlyProperty),
            ScanResult(declaration: delegate, annotation: .unassignedOptionalProperty),
            ScanResult(declaration: marker, annotation: .redundantProtocol(references: Set(references), inherited: ["Sendable"])),
            ScanResult(declaration: helper, annotation: .redundantPublicAccessibility(modules: ["Lib"])),
            ScanResult(declaration: base, annotation: .redundantOpenAccessibility(modules: ["Lib"])),
            ScanResult(declaration: leaf, annotation: .missingFinal),
            ScanResult(declaration: tag, annotation: .redundantAccessLevel(RedundantAccessLevel(accessibility: .internal, context: nil))),
            ScanResult(declaration: emptyExtension, annotation: .emptyExtension),
            ScanResult(declaration: legacy, annotation: .superfluousIgnoreCommand),
            ScanResult(declaration: retrying, annotation: .enumCaseNeverConstructed),
            ScanResult(declaration: blurr, annotation: .missingMetalFunction),
        ]
    }

    // MARK: - Private

    private func format(_ results: [ScanResult], root: String? = nil) throws -> String {
        let configuration = Configuration()
        configuration.projectRoot = FilePath(root ?? projectRoot)
        let formatter = JsonV2Formatter(configuration: configuration, logger: logger)
        formatter.toolVersion = "0.0.0"
        formatter.variants = ["arm64-apple-macosx"]
        return try XCTUnwrap(formatter.format(results, colored: false))
    }

    /// Through YAML rather than JSONSerialization: on Linux the latter turns booleans into `NSNumber` 0 and 1.
    private func document(_ output: String) throws -> [String: Any] {
        try XCTUnwrap(try Yams.load(yaml: output) as? [String: Any])
    }

    private func schema() throws -> [String: Any] {
        let data = try Data(contentsOf: ProjectRootPath.appending("schemas/output-v2.json").url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The ids of the results and of their related results, in document order.
    private func ids(_ output: String) throws -> [String] {
        let results = try document(output)["results"] as? [[String: Any]] ?? []
        return results.flatMap { result in
            [result["id"] as? String ?? ""] + (result["related"] as? [[String: Any]] ?? []).map { $0["id"] as? String ?? "" }
        }
    }

    private func paths(_ document: [String: Any]) -> [String] {
        let results = document["results"] as? [[String: Any]] ?? []
        return results.flatMap { result in
            [result["location"]].compactMap { ($0 as? [String: Any])?["path"] as? String }
                + (result["related"] as? [[String: Any]] ?? []).compactMap { ($0["location"] as? [String: Any])?["path"] as? String }
        }
    }
}
