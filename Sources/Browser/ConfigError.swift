/// Something wrong with the config file, which keeps it from being applied: where its text
/// isn't JSON, on a line; a key with a value it can't take, with the key; or with the whole
/// file, as one that can't be read (docs/decisions/0123-config-is-the-settings.md).
public struct ConfigError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The line it is on, counted from 1; nil for an error that isn't on a line.
    public let line: Int?
    /// The key it is about, as `ConfigFile` spells it, such as `show-hidden` or
    /// `shortcuts.window.showPalette.primary`; nil for an error with no key.
    public let key: String?
    /// What is wrong, in a phrase that names the key when there is one:
    /// `folders-first must be true or false, not "yes"`.
    public let reason: String

    public init(line: Int?, key: String?, reason: String) {
        self.line = line
        self.key = key
        self.reason = reason
    }

    /// The reason after the line it is on: `line 3: isn't valid JSON: …`.
    public var description: String {
        line.map { "line \($0): \(reason)" } ?? reason
    }
}
