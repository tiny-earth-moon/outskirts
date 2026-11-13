@testable import Indexer
@testable import SyntaxAnalysis
import XCTest

final class LocalizedStringCallResolverTest: XCTestCase {
    private typealias Parameter = LocalizedStringCallResolver.Parameter
    private typealias Argument = LocalizedStringCallSite.Argument

    func testDemanglesSwiftUSR() {
        let demangled = LocalizedStringCallResolver.demangle(
            usr: "s:7SwiftUI6ButtonVA2A4TextVRszrlE_6actionACyAEGAA18LocalizedStringKeyV_yyctcfc"
        )

        XCTAssertEqual(
            demangled,
            "(extension in SwiftUI):SwiftUI.Button< where A == SwiftUI.Text>.init(_: SwiftUI.LocalizedStringKey, action: () -> ()) -> SwiftUI.Button<SwiftUI.Text>"
        )
    }

    func testDoesNotDemangleNonSwiftUSR() {
        XCTAssertNil(LocalizedStringCallResolver.demangle(usr: "c:objc(cs)NSAlert(im)addButtonWithTitle:"))
    }

    func testParsesLabeledParameters() {
        let parameters = LocalizedStringCallResolver.parameters(
            fromDemangledSignature: "(extension in SwiftUI):SwiftUI.Label< where A == SwiftUI.Text, B == SwiftUI.Image>.init(_: SwiftUI.LocalizedStringKey, systemImage: Swift.String) -> SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>"
        )

        XCTAssertEqual(parameters, [
            Parameter(label: nil, type: "SwiftUI.LocalizedStringKey"),
            Parameter(label: "systemImage", type: "Swift.String"),
        ])
    }

    func testParsesUnlabeledParameters() {
        let parameters = LocalizedStringCallResolver.parameters(
            fromDemangledSignature: "(extension in SwiftUI):SwiftUI.View.navigationTitle(SwiftUI.LocalizedStringKey) -> some"
        )

        XCTAssertEqual(parameters, [Parameter(label: nil, type: "SwiftUI.LocalizedStringKey")])
    }

    func testParsesFunctionTypeParameters() {
        let parameters = LocalizedStringCallResolver.parameters(
            fromDemangledSignature: "Module.run<A where A: Swift.StringProtocol>(_: A, completion: (Swift.Int, Swift.String) -> (), title: [Swift.String: Foundation.LocalizedStringResource]) -> ()"
        )

        XCTAssertEqual(parameters, [
            Parameter(label: nil, type: "A"),
            Parameter(label: "completion", type: "(Swift.Int, Swift.String) -> ()"),
            Parameter(label: "title", type: "[Swift.String: Foundation.LocalizedStringResource]"),
        ])
    }

    func testSkipsPrivateDiscriminator() {
        let parameters = LocalizedStringCallResolver.parameters(
            fromDemangledSignature: "Module.Controller.(showAlert in _81AE913598B2E23132B3415B5C7CAFDE)(title: SwiftUI.LocalizedStringKey) -> ()"
        )

        XCTAssertEqual(parameters, [Parameter(label: "title", type: "SwiftUI.LocalizedStringKey")])
    }

    func testParsesEmptyParameterList() {
        XCTAssertEqual(LocalizedStringCallResolver.parameters(fromDemangledSignature: "Module.run() -> ()"), [])
    }

    func testMatchesArgumentsToParametersSkippingDefaults() {
        let parameters = [
            Parameter(label: nil, type: "SwiftUI.LocalizedStringKey"),
            Parameter(label: "tableName", type: "Swift.Optional<Swift.String>"),
            Parameter(label: "comment", type: "Swift.Optional<Swift.StaticString>"),
        ]
        let arguments = [
            Argument(label: nil, keys: ["key"]),
            Argument(label: "comment", keys: ["comment"]),
        ]

        XCTAssertEqual(LocalizedStringCallResolver.usedKeys(for: arguments, parameters: parameters), ["key"])
    }

    func testMatchesVariadicArguments() {
        let parameters = [Parameter(label: nil, type: "Foundation.LocalizedStringResource...")]
        let arguments = [Argument(label: nil, keys: ["a"]), Argument(label: nil, keys: ["b"])]

        XCTAssertEqual(LocalizedStringCallResolver.usedKeys(for: arguments, parameters: parameters), ["a", "b"])
    }

    func testRetainsUnmatchedArguments() {
        let parameters = [Parameter(label: "title", type: "Swift.String")]
        let arguments = [Argument(label: "other", keys: ["unmatched"])]

        XCTAssertEqual(LocalizedStringCallResolver.usedKeys(for: arguments, parameters: parameters), ["unmatched"])
    }

    func testFindsStringKeyParametersOfLocalizedInitializers() {
        let signatures: [(String, Set<String?>)] = [
            ("SwiftUI.LocalizedStringKey.init(Swift.String) -> SwiftUI.LocalizedStringKey", [nil, "stringLiteral"]),
            (
                "(extension in Foundation):Swift.String.LocalizationValue.init(stringLiteral: Swift.String) -> (extension in Foundation):Swift.String.LocalizationValue",
                [nil, "stringLiteral"]
            ),
            (
                "Foundation.LocalizedStringResource.init(_: Swift.StaticString, defaultValue: (extension in Foundation):Swift.String.LocalizationValue, table: Swift.String?) -> Foundation.LocalizedStringResource",
                [nil, "stringLiteral"]
            ),
            (
                "(extension in Foundation):Swift.String.init(localized: Swift.StaticString, defaultValue: (extension in Foundation):Swift.String.LocalizationValue, table: Swift.String?) -> Swift.String",
                ["localized"]
            ),
            ("Module.Wrapper<A>.init<B where B: Swift.StringProtocol>(B) -> Module.Wrapper<A>", []),
            ("Module.Name.init(Swift.String) -> Module.Name", []),
            ("Module.LocalizedStringKeyBox.init(Swift.String) -> Module.LocalizedStringKeyBox", []),
            ("Module.show(Swift.String) -> ()", []),
        ]

        for (signature, labels) in signatures {
            XCTAssertEqual(LocalizedStringCallResolver.stringKeyLabels(ofDemangledSignature: signature), labels, signature)
        }
    }

    func testRetainsPlainStringKeysOfLocalizedInitializers() {
        let parameters = [
            Parameter(label: nil, type: "Swift.StaticString"),
            Parameter(label: "table", type: "Swift.String?"),
        ]
        let arguments = [Argument(label: nil, keys: ["key"]), Argument(label: "table", keys: ["Table"])]

        XCTAssertEqual(LocalizedStringCallResolver.usedKeys(for: arguments, parameters: parameters, stringKeyLabels: [nil]), ["key"])
        XCTAssertEqual(LocalizedStringCallResolver.usedKeys(for: arguments, parameters: parameters), [])
    }

    func testMatchesTrailingClosureToNextFunctionParameter() {
        let parameters = [
            Parameter(label: nil, type: "Swift.String"),
            Parameter(label: "make", type: "() -> SwiftUI.LocalizedStringKey"),
            Parameter(label: "plain", type: "() -> Swift.String"),
        ]
        let arguments = [
            Argument(label: nil, keys: ["string_key"]),
            Argument(label: nil, keys: ["closure_key"], isTrailingClosure: true),
            Argument(label: "plain", keys: ["plain_closure_key"]),
        ]

        XCTAssertEqual(LocalizedStringCallResolver.usedKeys(for: arguments, parameters: parameters), ["closure_key"])
        XCTAssertEqual(
            LocalizedStringCallResolver.usedKeys(
                for: [Argument(label: nil, keys: ["defaulted_closure_key"], isTrailingClosure: true)],
                parameters: parameters
            ),
            ["defaulted_closure_key"]
        )
        XCTAssertEqual(
            LocalizedStringCallResolver.usedKeys(
                for: [Argument(label: nil, keys: ["map_key"], isTrailingClosure: true)],
                parameters: [Parameter(label: nil, type: "(A) throws(B) -> C")]
            ),
            []
        )
    }

    func testRetainsTrailingClosureKeysWhenAnySkippableParameterTakesAKey() {
        // `g(_ a: (() -> String)? = nil, _ b: () -> LocalizedStringKey)` called as `g { "key" }` passes the closure to
        // `b`; default values are not in the signature, so every candidate before the next labeled argument counts.
        let parameters = [
            Parameter(label: nil, type: "(() -> Swift.String)?"),
            Parameter(label: nil, type: "() -> SwiftUI.LocalizedStringKey"),
            Parameter(label: "footer", type: "() -> Swift.String"),
        ]

        XCTAssertEqual(
            LocalizedStringCallResolver.usedKeys(
                for: [
                    Argument(label: nil, keys: ["closure_key"], isTrailingClosure: true),
                    Argument(label: "footer", keys: ["footer_key"]),
                ],
                parameters: parameters
            ),
            ["closure_key"]
        )
        XCTAssertEqual(
            LocalizedStringCallResolver.usedKeys(
                for: [Argument(label: nil, keys: ["string_closure_key"], isTrailingClosure: true)],
                parameters: [Parameter(label: nil, type: "(() -> Swift.String)?"), parameters[2]]
            ),
            []
        )
    }

    func testDoesNotRetainKeysOfClosuresTakingLocalizedArguments() {
        let parameters = [Parameter(label: nil, type: "(SwiftUI.LocalizedStringKey) -> Swift.String")]
        let arguments = [Argument(label: nil, keys: ["closure_argument_key"], isTrailingClosure: true)]

        XCTAssertEqual(LocalizedStringCallResolver.usedKeys(for: arguments, parameters: parameters), [])
    }

    func testReadsTheReturnTypeOfFunctionTypes() {
        let types: [(String, String)] = [
            ("(SwiftUI.LocalizedStringKey) -> Swift.String", "Swift.String"),
            ("@escaping @Sendable () -> SwiftUI.LocalizedStringKey", "SwiftUI.LocalizedStringKey"),
            ("((Swift.Int) -> Foundation.LocalizedStringResource)?", "Foundation.LocalizedStringResource"),
            ("(Swift.Int) -> (Swift.String) -> SwiftUI.LocalizedStringKey", "SwiftUI.LocalizedStringKey"),
            ("(A) async throws(B) -> C", "C"),
            ("[Swift.String: SwiftUI.LocalizedStringKey]", "[Swift.String: SwiftUI.LocalizedStringKey]"),
            ("(SwiftUI.LocalizedStringKey, Swift.Int)?", "(SwiftUI.LocalizedStringKey, Swift.Int)?"),
        ]

        for (type, valueType) in types {
            XCTAssertEqual(LocalizedStringSyntaxVisitor.valueTypeName(of: type), valueType, type)
        }
    }

    func testResolvesSubscriptAccessors() {
        // `subscript(two a: String, _ b: LocalizedStringKey)`, called as `table[two: "first", "second"]`: the index
        // store records its getter at the opening bracket.
        let getter = "s:2cv3SubV3two_SiSS_7SwiftUI18LocalizedStringKeyVtcig"
        let twoArguments = LocalizedStringCallSite(line: 1, column: 1, arguments: [
            Argument(label: "two", keys: ["string_subscript_key"]),
            Argument(label: nil, keys: ["localized_subscript_key"]),
        ])

        XCTAssertEqual(
            LocalizedStringCallResolver.demangle(usr: getter),
            "cv.Sub.subscript.getter : (two: Swift.String, _: SwiftUI.LocalizedStringKey) -> Swift.Int"
        )
        XCTAssertEqual(LocalizedStringCallResolver.usedKeys(for: twoArguments, calleeUsrs: [getter]), ["localized_subscript_key"])

        let accessors: [(usr: String, isKey: Bool)] = [
            // `static subscript(_: LocalizedStringKey)`.
            ("s:2cv3SubVySi7SwiftUI18LocalizedStringKeyVcigZ", true),
            // The setter and the modify accessor of `subscript(label: LocalizedStringResource)`.
            ("s:2cv3BoxV5labelSi10Foundation23LocalizedStringResourceV_tcis", true),
            ("s:2cv3BoxV5labelSi10Foundation23LocalizedStringResourceV_tciM", true),
            // `subscript(label: String)`, `Dictionary<String, _>` and `Array`.
            ("s:2cv3BoxV5labelSiSS_tcig", false),
            ("s:SDyq_Sgxcig", false),
            ("s:SayxSicig", false),
        ]

        for (usr, isKey) in accessors {
            let label = usr.contains("label") ? "label" : nil
            let callSite = LocalizedStringCallSite(line: 1, column: 1, arguments: [Argument(label: label, keys: ["key"])])

            XCTAssertEqual(LocalizedStringCallResolver.usedKeys(for: callSite, calleeUsrs: [usr]), isKey ? ["key"] : [], usr)
        }
    }

    func testRetainsKeysOfUnresolvedCallee() {
        let callSite = LocalizedStringCallSite(line: 1, column: 1, arguments: [Argument(label: nil, keys: ["key"])])

        XCTAssertEqual(LocalizedStringCallResolver.usedKeys(for: callSite, calleeUsrs: []), ["key"])
        XCTAssertEqual(LocalizedStringCallResolver.usedKeys(for: callSite, calleeUsrs: ["c:objc(cs)NSAlert(im)addButtonWithTitle:"]), ["key"])
    }
}
