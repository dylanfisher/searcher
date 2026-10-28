import Foundation

extension Settings {
    /// A preference's value, as the config file spells it and `UserDefaults` stores it.
    public enum Value: Equatable, Sendable, CustomStringConvertible {
        case bool(Bool)
        case number(Double)
        case string(String)

        /// The value as the config file spells it: `true`, `320`, or a string in quotes, with a
        /// quote or backslash in it escaped.
        public var description: String {
            switch self {
            case .bool(let value):
                return value ? "true" : "false"
            case .number(let value):
                return value == value.rounded() && abs(value) < 1e15
                    ? String(Int64(value)) : String(value)
            case .string(let value):
                let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\""
            }
        }

        /// The value as `UserDefaults` stores it.
        var stored: Any {
            switch self {
            case .bool(let value): value
            case .number(let value): value
            case .string(let value): value
            }
        }
    }

    /// A preference the config file can set (`Settings.preferences`).
    public struct Preference: Sendable {
        /// What a preference accepts.
        public enum Kind: Sendable {
            /// `true` or `false`, unquoted.
            case bool
            /// An unquoted number `isValid` accepts, which `described` names in words.
            case number(isValid: @Sendable (Double) -> Bool, described: String)
            /// One of the names, quoted or not.
            case choice([String])
            /// Any string but the empty one, quoted or not.
            case string
        }

        let key: Key
        /// Its key in the config file: lowercase words joined by dashes.
        public let name: String
        let kind: Kind
        public let defaultValue: Value
        /// What it does, in a sentence, for the template's comment.
        public let summary: String

        init(_ key: Key, _ name: String, _ kind: Kind, default: Value, summary: String) {
            self.key = key
            self.name = name
            self.kind = kind
            defaultValue = `default`
            self.summary = summary
        }

        /// Whether the preference can hold `value`.
        func accepts(_ value: Value) -> Bool {
            switch (kind, value) {
            case (.bool, .bool): true
            case (.number(let isValid, _), .number(let number)): isValid(number)
            case (.choice(let names), .string(let string)): names.contains(string)
            case (.string, .string(let string)): !string.isEmpty
            default: false
            }
        }
    }

    /// A preference whose value set in the app differs from the config file's, which it wins
    /// over.
    public struct ConfigOverride: Equatable, Sendable {
        let key: Key
        /// The preference's key in the config file.
        public let name: String
        public let appValue: Value
        public let fileValue: Value
    }
}
