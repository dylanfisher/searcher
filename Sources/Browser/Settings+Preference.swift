import Foundation

extension Settings {
    /// A preference's value.
    public enum Value: Equatable, Sendable, CustomStringConvertible {
        case bool(Bool)
        case number(Double)
        case string(String)

        /// The value as JSON spells it: `true`, `320`, or a string in quotes, with a quote or
        /// backslash in it escaped.
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
    }

    /// A preference the config file can set (`Settings.preferences`).
    public struct Preference: Sendable {
        /// What a preference accepts.
        public enum Kind: Sendable {
            /// `true` or `false`.
            case bool
            /// A number `isValid` accepts, which `described` names in words.
            case number(isValid: @Sendable (Double) -> Bool, described: String)
            /// One of the names, as a string.
            case choice([String])
            /// Any string but the empty one.
            case string
        }

        let key: Key
        /// Its key in the config file: lowercase words joined by dashes.
        public let name: String
        let kind: Kind
        public let defaultValue: Value
        /// What the preference does, in a sentence: the comment above its key in the config
        /// file the app writes, as in Sublime Text's settings
        /// (docs/decisions/0126-config-comments.md).
        public let summary: String

        init(_ key: Key, _ name: String, _ kind: Kind, default: Value, _ summary: String) {
            self.key = key
            self.name = name
            self.kind = kind
            defaultValue = `default`
            self.summary = summary
        }

        /// What the preference takes, in words: `true or false`, `"auto", "light" or "dark"`.
        /// Its error and its comment in the file both say it.
        var takes: String {
            switch kind {
            case .bool:
                return "true or false"
            case .number(_, let described):
                return described
            case .choice(let names):
                let quoted = names.map { "\"\($0)\"" }
                guard let last = quoted.last, quoted.count > 1 else { return quoted.joined() }
                return quoted.dropLast().joined(separator: ", ") + " or " + last
            case .string:
                return "a string that isn't empty"
            }
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
}
