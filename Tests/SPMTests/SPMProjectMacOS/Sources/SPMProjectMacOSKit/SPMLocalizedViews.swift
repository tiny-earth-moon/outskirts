import AppIntents
import Foundation
import SwiftUI

public struct SPMLocalizedView: View {
    @State private var isOn = false
    private let isPrimary = true
    private let name = "name"
    private let count = 3
    private let ratio = 0.5
    private let optionalKey: LocalizedStringKey? = nil
    private let optionalName: String? = nil
    @ObservedObject private var model = SPMLocalizedModel()

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section("mac_section_key") {
                    Button("mac_button_key") {}
                    Label("mac_label_key", systemImage: "mac_label_system_image_key")
                    Toggle("mac_toggle_key", isOn: $isOn)
                    Text("mac_text_key")
                    Text(isPrimary ? "mac_ternary_true_key" : "mac_ternary_false_key")
                    SPMCustomRow(title: "mac_custom_init_key")
                    SPMCustomRow()
                    Text("mac_interpolated_string_key \(name)")
                    Button("mac_interpolated_int_key \(count)") {}
                    Text("mac_interpolated_double_key \(ratio)")
                    SPMLockNote(model: model, messageKey: "mac_struct_init_key")
                    SPMPanelButton(title: "mac_struct_trailing_key", systemImage: "mac_struct_image_key") {}
                    Text(optionalKey ?? "mac_coalesce_key")
                    Text(optionalName ?? "mac_coalesce_string_key")
                    Text("mac_cast_key" as LocalizedStringKey)
                }
            }
            .navigationTitle("mac_navigation_title_key")
        }
    }
}

final class SPMLocalizedModel: ObservableObject {}

struct SPMLockNote: View {
    @ObservedObject var model: SPMLocalizedModel
    let messageKey: LocalizedStringKey

    var body: some View {
        Text(messageKey)
    }
}

struct SPMPanelButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
    }
}

public struct SPMCustomRow: View {
    let title: LocalizedStringKey

    public init(title: LocalizedStringKey = "mac_default_value_key") {
        self.title = title
    }

    public var body: some View {
        Text(title)
    }
}

public enum SPMLocalizedStrings {
    public static let annotatedProperty: LocalizedStringResource = "mac_annotated_property_key"

    public static var returnedResource: LocalizedStringResource {
        "mac_returned_resource_key"
    }

    public static let typedArray: [LocalizedStringResource] = ["mac_typed_array_key"]
    public static let typedDictionary: [Int: LocalizedStringResource] = [1: "mac_typed_dictionary_key"]
    public static let typedTuple: (LocalizedStringResource, String) = ("mac_typed_tuple_key", "mac_typed_tuple_symbol_key")

    public static func switchKey(_ isFirst: Bool) -> LocalizedStringKey {
        switch isFirst {
        case true: "mac_switch_first_key"
        case false: "mac_switch_second_key"
        }
    }

    public static func ternaryKey(_ count: Int) -> LocalizedStringKey {
        count == 0 ? "mac_ternary_return_key" : "mac_ternary_return_count_key \(count)"
    }

    public static func resource(_ resource: LocalizedStringResource) -> String {
        String(localized: resource)
    }

    public static func localizationValue(_ value: String.LocalizationValue) -> String {
        String(localized: value)
    }

    public static func plain(_ value: String) -> String {
        value
    }

    public static func variadic(_ values: LocalizedStringResource...) -> Int {
        values.count
    }

    public static func key(_ key: LocalizedStringKey) -> LocalizedStringKey {
        key
    }

    public static func closureKey(_ make: () -> LocalizedStringKey) -> LocalizedStringKey {
        make()
    }

    public static func closureString(_ make: () -> String) -> String {
        make()
    }

    public static func forward(_ header: (() -> String)? = nil, _ content: () -> LocalizedStringKey) -> LocalizedStringKey {
        _ = header?()
        return content()
    }

    public static func describe(_ format: (LocalizedStringKey) -> String) -> String {
        format("mac_closure_argument_key")
    }

    public static func use() {
        _ = resource("mac_resource_param_key")
        _ = localizationValue("mac_localization_value_param_key")
        _ = plain("mac_plain_string_param_key")
        _ = variadic("mac_variadic_key", "mac_variadic_key")
        _ = key(.init("mac_dot_init_key"))
        _ = SPMTitledItem(title: .init("mac_memberwise_init_key"))
        _ = [.init("mac_value_init_key")] as [String.LocalizationValue]
        _ = String(localized: .init("mac_localized_value_init_key"))
        let string: String = .init(localized: "mac_string_init_key", defaultValue: "Default")
        let resource: LocalizedStringResource = .init("mac_resource_init_key", defaultValue: "Default")
        let plainName: SPMPlainName = .init("mac_plain_init_key")
        _ = (string, resource, plainName)
        _ = closureKey { "mac_trailing_closure_key" }
        _ = closureString { "mac_trailing_closure_string_key" }
        _ = forward { "mac_forward_scan_key" }
        _ = describe { _ in "mac_closure_argument_string_key" }
        _ = SPMLocalizedBanner.title()
        useSubscripts()
    }

    static func useSubscripts() {
        let table = SPMLocalizedTable()
        let counts: [String: Int] = [:]
        _ = table["mac_subscript_key"]
        _ = table[resource: "mac_labeled_subscript_key"]
        _ = SPMLocalizedTable["mac_static_subscript_key"]
        _ = table.nested["mac_chained_subscript_key"]
        _ = table.lookUp()
        _ = table[plain: "mac_plain_subscript_key"]
        _ = counts["mac_dictionary_subscript_key"]
    }
}

struct SPMTitledItem {
    let title: LocalizedStringKey
}

struct SPMPlainName {
    init(_: String) {}
}

public enum SPMLocalizedBanner {
    case title(LocalizedStringKey = "mac_case_default_key")
}

struct SPMLocalizedTable {
    static subscript(_: LocalizedStringKey) -> Int {
        0
    }

    subscript(_: LocalizedStringKey) -> Int {
        0
    }

    subscript(resource _: LocalizedStringResource) -> Int {
        0
    }

    subscript(plain _: String) -> Int {
        0
    }

    var nested: Self {
        self
    }

    func lookUp() -> Int {
        self["mac_self_subscript_key"]
    }
}
