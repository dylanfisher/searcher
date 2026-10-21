/// The stable name of a command. Menus, key bindings and settings refer to commands by ID.
public struct CommandID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}
