/// Something wrong with the config file, which keeps it from being applied: on a line, with the
/// key the line sets when it has one, or with the whole file, as one that can't be read.
public struct ConfigError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The line it is on, counted from 1; nil for an error with the whole file.
    public let line: Int?
    /// The key the line sets, as written; nil when the line has none, or the error isn't on a
    /// line.
    public let key: String?
    /// What is wrong, in a phrase: `folders-first must be true or false, not "yes"`.
    public let reason: String

    public init(line: Int?, key: String?, reason: String) {
        self.line = line
        self.key = key
        self.reason = reason
    }

    /// The reason after the line it is on: `line 3: unknown key "show-hiden"`.
    public var description: String {
        line.map { "line \($0): \(reason)" } ?? reason
    }
}
