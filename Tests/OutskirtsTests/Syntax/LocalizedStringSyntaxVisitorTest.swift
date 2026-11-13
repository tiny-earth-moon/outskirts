import Foundation
import Logger
import Shared
@testable import SourceGraph
@testable import SyntaxAnalysis
import SystemPackage
@testable import TestShared
import XCTest

final class LocalizedStringSyntaxVisitorTest: XCTestCase {
    func testDetectsNSLocalizedString() throws {
        let usedKeys = try collectUsedStringKeys(from: """
        let greeting = NSLocalizedString("hello_world", comment: "")
        let farewell = NSLocalizedString("goodbye", tableName: "Other", comment: "")
        """)

        XCTAssertEqual(usedKeys, ["hello_world", "goodbye"])
    }

    func testDetectsStringLocalized() throws {
        let usedKeys = try collectUsedStringKeys(from: """
        let greeting = String(localized: "welcome_message")
        let farewell = String(localized: "farewell_message", table: "Main")
        """)

        XCTAssertEqual(usedKeys, ["welcome_message", "farewell_message"])
    }

    func testDetectsLocalizedStringKey() throws {
        let usedKeys = try collectUsedStringKeys(from: """
        let key = LocalizedStringKey("settings_title")
        """)

        XCTAssertEqual(usedKeys, ["settings_title"])
    }

    func testDetectsLocalizedStringResource() throws {
        let usedKeys = try collectUsedStringKeys(from: """
        let resource = LocalizedStringResource("resource_key")
        """)

        XCTAssertEqual(usedKeys, ["resource_key"])
    }

    func testDetectsSwiftUIText() throws {
        let usedKeys = try collectUsedStringKeys(from: """
        Text("button_label")
        """)

        XCTAssertEqual(usedKeys, ["button_label"])
    }

    func testDetectsBundleLocalizedString() throws {
        let usedKeys = try collectUsedStringKeys(from: """
        Bundle.main.localizedString(forKey: "bundle_key", value: nil, table: nil)
        """)

        XCTAssertEqual(usedKeys, ["bundle_key"])
    }

    func testNormalizesStringInterpolationsToFormatKeys() throws {
        let usedKeys = try collectUsedStringKeys(from: ##"""
        let greeting = NSLocalizedString("hello \(name)", comment: "")
        Text("count \(42) items")
        Text("ratio \(0.5) and \(-3)")
        Text("progress \(value, specifier: "%.1f") at 100%")
        Text(#"raw \#(name) \n"#)
        """##)

        XCTAssertEqual(usedKeys, [
            "hello %@", "count %lld items", "ratio %lf and %lld", "progress %.1f at 100%%", #"raw %@ \n"#,
        ])
    }

    func testMultipleKeys() throws {
        let usedKeys = try collectUsedStringKeys(from: """
        NSLocalizedString("key1", comment: "")
        String(localized: "key2")
        Text("key3")
        LocalizedStringKey("key4")
        """)

        XCTAssertEqual(usedKeys, ["key1", "key2", "key3", "key4"])
    }

    func testResolvesEscapeSequences() throws {
        let usedKeys = try collectUsedStringKeys(from: #"""
        Text("line_one\nline_two")
        String(localized: "quoted \"key\"")
        NSLocalizedString(#"raw\key"#, comment: "")
        """#)

        XCTAssertEqual(usedKeys, ["line_one\nline_two", "quoted \"key\"", #"raw\key"#])
    }

    func testResolvesEscapedQuotesInKeysWithFormatSpecifiers() throws {
        let usedKeys = try collectUsedStringKeys(from: #"""
        String(format: String(localized: "You categorized %@ as \"%@\" %d times. Create an automatic rule?"), locale: .current, a, b, c)
        """#)

        XCTAssertEqual(usedKeys, [#"You categorized %@ as "%@" %d times. Create an automatic rule?"#])
    }

    func testResolvesEscapedQuotesInInterpolatedKeys() throws {
        let usedKeys = try collectUsedStringKeys(from: #"""
        String(localized: "Rule \"\(name)\" applied \(count) times")
        """#)

        XCTAssertEqual(usedKeys, [#"Rule "%@" applied %@ times"#])
    }

    func testResolvesTabAndBackslashEscapes() throws {
        let usedKeys = try collectUsedStringKeys(from: #"""
        Text("col\tone")
        Text("path\\to")
        Text("path\\\(name)\\end")
        Text("tab\t\(name)")
        """#)

        XCTAssertEqual(usedKeys, ["col\tone", #"path\to"#, #"path\%@\end"#, "tab\t%@"])
    }

    func testResolvesUnicodeEscapes() throws {
        let usedKeys = try collectUsedStringKeys(from: #"""
        Text("caf\u{E9} \u{1F600}")
        Text("caf\u{E9} \(name)")
        """#)

        XCTAssertEqual(usedKeys, ["caf\u{E9} \u{1F600}", "caf\u{E9} %@"])
    }

    func testResolvesMultilineStrings() throws {
        let usedKeys = try collectUsedStringKeys(from: #"""
        Text("""
            first \"line\"
              second\tline
            """)
        Text("""
            first \(name)
            second "line"
            """)
        """#)

        XCTAssertEqual(usedKeys, ["first \"line\"\n  second\tline", "first %@\nsecond \"line\""])
    }

    func testResolvesRawStringEscapes() throws {
        let usedKeys = try collectUsedStringKeys(from: ##"""
        Text(#"raw "quoted" \n \#(name)"#)
        Text(#"raw \#n \#"x\#" \#(name)"#)
        """##)

        XCTAssertEqual(usedKeys, [#"raw "quoted" \n %@"#, "raw \n \"x\" %@"])
    }

    func testIgnoresTextVerbatim() throws {
        let usedKeys = try collectUsedStringKeys(from: """
        Text(verbatim: "not_a_key")
        """)

        XCTAssertEqual(usedKeys, [])
    }

    func testIgnoresUnsupportedForms() throws {
        let usedKeys = try collectUsedStringKeys(from: """
        let key = "dynamic_key"
        String(localized: .generatedSymbolKey)
        Text(.generatedSymbolKey)
        String(localized: String.LocalizationValue(key))
        NSLocalizedString(key, comment: "")
        Text(key)
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        """)

        XCTAssertEqual(usedKeys, [])
    }

    func testTableAndBundleArgumentsDoNotPreventDetection() throws {
        let usedKeys = try collectUsedStringKeys(from: """
        String(localized: "table_key", table: "Other", bundle: .module)
        Text("text_table_key", tableName: "Other", bundle: .module)
        """)

        XCTAssertEqual(usedKeys, ["table_key", "text_table_key"])
    }

    func testDetectsLiteralsOfLocalizedDeclarationTypes() throws {
        let usedKeys = try collectUsedStringKeys(from: """
        let key: LocalizedStringKey = "annotated_key"
        let plain: String = "plain_key"
        var resource: LocalizedStringResource { condition ? "computed_true_key" : "computed_false_key" }
        func title() -> String.LocalizationValue {
            if value == "condition_key" { return "returned_key" }
            return format("argument_key")
        }
        func row(title: LocalizedStringKey = "default_key", detail: String = "string_default_key") {}
        """)

        XCTAssertEqual(usedKeys, [
            "annotated_key", "computed_true_key", "computed_false_key", "returned_key", "default_key",
        ])
    }

    func testDetectsLiteralsReturnedFromSwitchAndIf() throws {
        let usedKeys = try collectUsedStringKeys(from: """
        static func graphicsKey(_ quality: Quality) -> LocalizedStringKey {
            switch quality {
            case .auto: "switch_auto_key"
            case .low: return "switch_low_key"
            }
        }
        var stageKey: LocalizedStringResource? {
            if isFirst { "if_true_key" } else { "if_false_key" }
        }
        let title: LocalizedStringKey = switch mode {
        case .compact: "switch_expression_key"
        default: "switch_default_key"
        }
        func plain() -> String {
            switch mode { case .compact: "plain_switch_key" }
        }
        """)

        XCTAssertEqual(usedKeys, [
            "switch_auto_key", "switch_low_key", "if_true_key", "if_false_key", "switch_expression_key",
            "switch_default_key",
        ])
    }

    func testDetectsLiteralsReturnedFromClosures() throws {
        let usedKeys = try collectUsedStringKeys(from: """
        let label: (Int) -> LocalizedStringKey = { count in count == 0 ? "closure_empty_key" : "closure_count_key \\(count)" }
        let lazyTitle: LocalizedStringKey = { "applied_closure_key" }()
        let plain: () -> String = { "plain_closure_key" }
        """)

        XCTAssertEqual(usedKeys, ["closure_empty_key", "closure_count_key %@", "applied_closure_key"])
    }

    func testDetectsTernaries() throws {
        let usedKeys = try collectUsedStringKeys(from: """
        static func valueKey(remaining: Int) -> LocalizedStringKey {
            remaining == 0 ? "ternary_empty_key" : "ternary_value_key \\(remaining)"
        }
        Text(isOn ? "text_on_key" : "text_off_key")
        String(localized: isOn ? "localized_on_key" : "localized_off_key")
        """)

        XCTAssertEqual(usedKeys, [
            "ternary_empty_key", "ternary_value_key %@", "text_on_key", "text_off_key", "localized_on_key",
            "localized_off_key",
        ])
    }

    func testDetectsNestedTernaryKeys() throws {
        let usedKeys = try collectUsedStringKeys(from: """
        String(localized: a ? "nested_first_key" : b ? "nested_second_key" : "nested_third_key")
        NSLocalizedString(flag ? "ns_on_key" : (other ? "ns_inner_on_key" : "ns_inner_off_key"), comment: "")
        String(localized: (a ? "paren_on_key" : "paren_off_key"))
        """)

        XCTAssertEqual(usedKeys, [
            "nested_first_key", "nested_second_key", "nested_third_key", "ns_on_key", "ns_inner_on_key",
            "ns_inner_off_key", "paren_on_key", "paren_off_key",
        ])
    }

    func testDetectsNilCoalescingOperands() throws {
        let usedKeys = try collectUsedStringKeys(from: """
        let key: LocalizedStringKey = optionalKey ?? "coalesce_let_key"
        String(localized: isOn ? "coalesce_then_key" : (optionalValue ?? "coalesce_in_ternary_key"))
        NSLocalizedString(first ?? second ?? "coalesce_chain_key", comment: "")
        LocalizedStringKey(try optionalKey() ?? "coalesce_try_key")
        LocalizedStringKey(await optionalKey() ?? "coalesce_await_key")
        let plain: String = optionalString ?? "plain_coalesce_key"
        String(localized: name == "compared_key" ? "compared_then_key" : "compared_else_key")
        """)

        XCTAssertEqual(usedKeys, [
            "coalesce_let_key", "coalesce_then_key", "coalesce_in_ternary_key", "coalesce_chain_key",
            "coalesce_try_key", "coalesce_await_key", "compared_then_key", "compared_else_key",
        ])
    }

    func testLeavesNilCoalescingTextArgumentsToCallSiteResolution() throws {
        let visitor = try visit("""
        Text(optionalKey ?? "text_coalesce_key")
        Text(isOn ? optionalString ?? "text_ternary_coalesce_key" : "text_else_key")
        """)

        // `Text(optionalString ?? "key")` calls the verbatim initializer: the index decides from the called overload.
        XCTAssertEqual(visitor.usedStringKeys, [])
        XCTAssertEqual(visitor.callSites.map(\.allKeys), [
            ["text_coalesce_key"], ["text_ternary_coalesce_key", "text_else_key"],
        ])
    }

    func testRecordsNilCoalescingOperandsOfCallSites() throws {
        let callSites = try collectCallSites(from: """
        view.navigationTitle(optionalKey ?? "coalesce_navigation_key")
        """)

        XCTAssertEqual(callSites.first?.arguments, [.init(label: nil, keys: ["coalesce_navigation_key"])])
    }

    func testDetectsLiteralsCastToLocalizedTypes() throws {
        let usedKeys = try collectUsedStringKeys(from: """
        let key = "cast_let_key" as LocalizedStringKey
        Text("cast_argument_key" as LocalizedStringKey)
        show(optionalKey ?? "cast_coalesce_key" as LocalizedStringKey)
        let resource = ("cast_paren_key") as LocalizedStringResource
        let value = "cast_value_key" as String.LocalizationValue
        Text("cast_string_key" as String)
        let optional = "cast_optional_key" as? LocalizedStringKey
        """)

        XCTAssertEqual(usedKeys, [
            "cast_let_key", "cast_argument_key", "cast_coalesce_key", "cast_paren_key", "cast_value_key",
        ])
    }

    func testCollectsRuntimeKeysWithPrefixAndBundleScope() throws {
        let visitor = try visit("""
        NSLocalizedString(name, comment: "")
        NSLocalizedString("settings." + name, bundle: .module, comment: "")
        NSLocalizedString("row.\\(index).title", comment: "")
        Bundle.module.localizedString(forKey: "menu.\\(id)", value: nil, table: nil)
        LocalizedStringKey(flag ? "known_key" : name)
        String.LocalizationValue(name)
        LocalizedStringResource(name, bundle: Bundle.module)
        """)

        let keys = visitor.unresolvedKeys.map { "\($0.prefix)|\($0.bundleScope)" }
        XCTAssertEqual(keys, [
            "|unknown", "settings.|module", "row.|unknown", "menu.|module", "|unknown", "|unknown", "|module",
        ])
        XCTAssertTrue(visitor.usedStringKeys.contains("known_key"))
    }

    func testCollectsUnprefixedRuntimeKeysOfEveryLookup() throws {
        let visitor = try visit("""
        NSLocalizedString(key, tableName: "Other", comment: "")
        String(localized: String.LocalizationValue(key))
        LocalizedStringKey(key)
        Text(LocalizedStringKey(key))
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        Bundle.module.localizedAttributedString(forKey: key, value: nil, table: nil)
        """)

        let keys = visitor.unresolvedKeys.map { "\($0.prefix)|\($0.bundleScope)|\($0.line)" }
        XCTAssertEqual(keys, [
            "|unknown|1", "|unknown|2", "|unknown|3", "|unknown|4", "|unknown|5", "|module|6",
        ])
    }

    func testDetectsLocalizedAttributedStringLiteralKey() throws {
        let usedKeys = try collectUsedStringKeys(from: """
        let text = Bundle.main.localizedAttributedString(forKey: "attributed_key", value: nil, table: nil)
        """)

        XCTAssertEqual(usedKeys, ["attributed_key"])
    }

    func testLiteralAndFormatKeysAreNotRuntimeKeys() throws {
        let visitor = try visit("""
        NSLocalizedString("plain_key", comment: "")
        NSLocalizedString(a ? "first_key" : b ? "second_key" : "third_key", comment: "")
        LocalizedStringKey("count \\(count) items")
        String.LocalizationValue(("wrapped_key"))
        Bundle.main.localizedString(forKey: "lookup_key", value: nil, table: nil)
        String(localized: value)
        Text(title)
        """)

        XCTAssertEqual(visitor.unresolvedKeys, [])
    }

    func testDetectsTypedArrayDictionaryAndTupleElements() throws {
        let usedKeys = try collectUsedStringKeys(from: """
        let array: [LocalizedStringResource] = ["array_key", "array_other_key"]
        static let labels: [Pose: String.LocalizationValue] = [.standing: "dictionary_value_key"]
        static let symbols: [String: LocalizedStringKey] = ["dictionary_string_key": "dictionary_localized_key"]
        let options: [(LocalizedStringKey, Int)] = [("tuple_array_key", 1)]
        let pair: (title: LocalizedStringKey, symbol: String) = (title: "tuple_key", symbol: "tuple_symbol_key")
        let optionalArray: [LocalizedStringKey]? = ["optional_array_key"]
        """)

        XCTAssertEqual(usedKeys, [
            "array_key", "array_other_key", "dictionary_value_key", "dictionary_localized_key", "tuple_array_key",
            "tuple_key", "optional_array_key",
        ])
    }

    func testRecordsTupleAndClosureArgumentsOfCallSites() throws {
        let callSites = try collectCallSites(from: """
        row(title: ("tuple_argument_key"), make: { "closure_argument_key" })
        """)

        XCTAssertEqual(callSites.first?.arguments, [
            .init(label: "title", keys: ["tuple_argument_key"]),
            .init(label: "make", keys: ["closure_argument_key"]),
        ])
    }

    func testRecordsCallSitesForResolution() throws {
        let callSites = try collectCallSites(from: """
        Button("button_key") {}
        view.navigationTitle(isPrimary ? "primary_key" : "secondary_key")
        Label("label_key", systemImage: "star")
        Button(action: {}) { Text(verbatim: name) }
        """)

        XCTAssertEqual(callSites.map(\.line), [1, 2, 3])
        XCTAssertEqual(callSites.map(\.column), [1, 6, 1])
        XCTAssertEqual(callSites[0].arguments, [.init(label: nil, keys: ["button_key"])])
        XCTAssertEqual(callSites[1].arguments, [.init(label: nil, keys: ["primary_key", "secondary_key"])])
        XCTAssertEqual(callSites[2].arguments, [
            .init(label: nil, keys: ["label_key"]),
            .init(label: "systemImage", keys: ["star"]),
        ])
    }

    func testDetectsExplicitInitializerAndStringLiteralForms() throws {
        let usedKeys = try collectUsedStringKeys(from: """
        LocalizedStringKey.init("explicit_init_key")
        Text(LocalizedStringKey.init("text_explicit_init_key"))
        LocalizedStringKey(stringLiteral: "string_literal_key")
        String.LocalizationValue(stringLiteral: "value_string_literal_key")
        String.LocalizationValue.init("value_init_key")
        LocalizedStringResource.init("resource_init_key", defaultValue: "resource_default_key")
        String.init(localized: "string_init_key")
        Text.init(verbatim: "verbatim_key")
        LocalizedStringKey.init(verbatim: "labeled_key")
        """)

        XCTAssertEqual(usedKeys, [
            "explicit_init_key", "text_explicit_init_key", "string_literal_key", "value_string_literal_key",
            "value_init_key", "resource_init_key", "string_init_key",
        ])
    }

    func testRecordsImplicitInitializerCallSitesInEveryPosition() throws {
        let callSites = try collectCallSites(from: """
        show(.init("argument_init_key"))
        Item(title: .init("memberwise_init_key"))
        let keys: [LocalizedStringKey] = [.init("array_init_key")]
        make { .init("closure_init_key") }
        String(localized: .init("localization_value_init_key"))
        """)

        let initSites = callSites.filter { $0.arguments.map(\.label) == [nil] && $0.column > 1 }
        XCTAssertEqual(initSites.map(\.allKeys), [
            ["argument_init_key"], ["memberwise_init_key"], ["array_init_key"], ["closure_init_key"],
            ["localization_value_init_key"],
        ])
        XCTAssertEqual(initSites.map(\.column), [7, 14, 36, 9, 20])
    }

    func testCollectsRuntimeKeysOfExplicitInitializerForms() throws {
        let visitor = try visit("""
        LocalizedStringKey.init(name)
        LocalizedStringKey(stringLiteral: name)
        String.LocalizationValue.init(name)
        """)

        XCTAssertEqual(visitor.unresolvedKeys.map(\.line), [1, 2, 3])
    }

    func testRecordsTrailingClosuresOfCallSites() throws {
        let callSites = try collectCallSites(from: """
        make { "trailing_closure_key" }
        pick(title: "title_key") { "first_closure_key" } detail: { "detail_closure_key" } _: { "unlabeled_closure_key" }
        """)

        XCTAssertEqual(callSites.map(\.arguments), [
            [.init(label: nil, keys: ["trailing_closure_key"], isTrailingClosure: true)],
            [
                .init(label: "title", keys: ["title_key"]),
                .init(label: nil, keys: ["first_closure_key"], isTrailingClosure: true),
                .init(label: "detail", keys: ["detail_closure_key"]),
                .init(label: nil, keys: ["unlabeled_closure_key"]),
            ],
        ])
    }

    func testDetectsEnumCaseDefaultAndRawValues() throws {
        let usedKeys = try collectUsedStringKeys(from: """
        enum Banner {
            case title(LocalizedStringKey = "case_default_key", symbol: String = "case_symbol_key")
            case detail(text: LocalizedStringResource? = "case_optional_default_key"), other(Int = 1)
        }
        enum Title: LocalizedStringKey {
            case greeting = "raw_value_key"
        }
        enum Plain: String {
            case greeting = "plain_raw_value_key"
        }
        """)

        XCTAssertEqual(usedKeys, ["case_default_key", "case_optional_default_key", "raw_value_key"])
    }

    func testDetectsOnlyReturnedLiteralsOfBodies() throws {
        let usedKeys = try collectUsedStringKeys(from: """
        func title() -> LocalizedStringKey {
            mode = "assigned_key"
            if mode == "condition_key" { return "returned_if_key" }
            let local = "local_key"
            defer { log = "defer_key" }
            #if DEBUG
            return mode == "ternary_condition_key" ? "debug_then_key" : "debug_else_key"
            #endif
            func helper() -> String { return "nested_helper_key" }
            return "returned_key"
        }
        var label: LocalizedStringKey {
            get { "getter_key" }
            set { stored = "setter_key" }
        }
        let make: () -> LocalizedStringKey = { mode = "closure_assign_key"; return "closure_returned_key" }
        """)

        XCTAssertEqual(usedKeys, [
            "returned_if_key", "debug_then_key", "debug_else_key", "returned_key", "getter_key", "closure_returned_key",
        ])
    }

    func testRecordsOnlyReturnedLiteralsOfTrailingClosures() throws {
        let callSites = try collectCallSites(from: """
        label { mode == "closure_condition_key" ? "closure_then_key" : "closure_else_key" }
        label { mode = "closure_assign_key"; return "closure_return_key" }
        """)

        XCTAssertEqual(callSites.map(\.allKeys), [
            ["closure_then_key", "closure_else_key"], ["closure_return_key"],
        ])
    }

    func testIgnoresClosureDeclarationsTakingLocalizedArguments() throws {
        let usedKeys = try collectUsedStringKeys(from: """
        let format: (LocalizedStringKey) -> String = { _ in "closure_string_key" }
        let make: @escaping () -> LocalizedStringKey = { "closure_key_key" }
        let optionalMake: (() -> LocalizedStringResource)? = { "optional_closure_key" }
        """)

        XCTAssertEqual(usedKeys, ["closure_key_key", "optional_closure_key"])
    }

    func testRetainsLiteralsPassedToUnlocatableCallees() throws {
        let usedKeys = try collectUsedStringKeys(from: """
        makeFormatter()("closure_key")
        """)

        XCTAssertEqual(usedKeys, ["closure_key"])
    }

    func testRecordsSubscriptCallSitesAtTheOpeningBracket() throws {
        let visitor = try visit("""
        _ = Sub()["subscript_key"]
        _ = table[label: "label_key"]
        _ = Table["static_key"]
        _ = self["self_key"]
        _ = a.b["chained_key"]
        _ = table[two: "first_key", "second_key"]
        _ = table[closure: { "closure_key" }]
        _ = table[index: 1] { "trailing_key" }
        _ = dict["dictionary_key"]
        _ = array[0]
        """)

        XCTAssertEqual(visitor.callSites.map(\.line), [1, 2, 3, 4, 5, 6, 7, 8, 9])
        XCTAssertEqual(visitor.callSites.map(\.column), [10, 10, 10, 9, 8, 10, 10, 10, 9])
        XCTAssertEqual(visitor.callSites.map(\.arguments), [
            [.init(label: nil, keys: ["subscript_key"])],
            [.init(label: "label", keys: ["label_key"])],
            [.init(label: nil, keys: ["static_key"])],
            [.init(label: nil, keys: ["self_key"])],
            [.init(label: nil, keys: ["chained_key"])],
            [.init(label: "two", keys: ["first_key"]), .init(label: nil, keys: ["second_key"])],
            [.init(label: "closure", keys: ["closure_key"])],
            [.init(label: "index", keys: []), .init(label: nil, keys: ["trailing_key"], isTrailingClosure: true)],
            [.init(label: nil, keys: ["dictionary_key"])],
        ])
        // Whether the literals are keys depends on the subscript parameter types, resolved from the index store.
        XCTAssertEqual(visitor.usedStringKeys, [])
    }

    // MARK: - Private

    private func collectCallSites(from source: String) throws -> [LocalizedStringCallSite] {
        try visit(source).callSites
    }

    private func collectUsedStringKeys(from source: String) throws -> Set<String> {
        try visit(source).usedStringKeys
    }

    private func visit(_ source: String) throws -> LocalizedStringSyntaxVisitor {
        // Create a temporary file with the source
        let tmpFile = uniqueTemporaryURL("LocalizedStringTest", suffix: ".swift")
        try source.write(to: tmpFile, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: tmpFile)
        }

        let path = FilePath(tmpFile.path)
        let sourceFile = SourceFile(path: path, modules: ["Test"])

        let shell = ShellImpl(logger: Logger(quiet: true, verbose: false, colorMode: .never))
        let swiftVersion = try SwiftVersion(shell: shell)
        let multiplexingVisitor = try MultiplexingSyntaxVisitor(file: sourceFile, swiftVersion: swiftVersion)
        let visitor = multiplexingVisitor.add(LocalizedStringSyntaxVisitor.self)
        multiplexingVisitor.visit()

        return visitor
    }
}
