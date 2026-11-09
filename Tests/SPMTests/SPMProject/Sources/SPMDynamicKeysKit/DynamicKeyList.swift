import Foundation

// `dyn_comment_only_key` is only named in this comment, which does not use it.
#if canImport(Darwin)
    public enum DynamicKeyList {
        public static func titles() -> [String] {
            let keys = ["dyn_literal_list_key"]
            return keys.map { key in
                Bundle.module.localizedString(forKey: key, value: nil, table: nil)
            }
        }
    }
#else
    public enum DynamicKeyList {
        public static func titles() -> [String] {
            []
        }
    }
#endif
