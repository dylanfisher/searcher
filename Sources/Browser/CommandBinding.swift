/// A command and what it does when it runs.
public struct CommandBinding: Sendable {
    public let command: Command
    public let run: @MainActor @Sendable (CommandContext) -> Void
    /// For a command that turns a setting on and off: whether it is on, which its menu item shows
    /// as a check mark. Nil for other commands.
    public let isChecked: (@MainActor @Sendable (Settings) -> Bool)?

    public init(
        _ command: Command, isChecked: (@MainActor @Sendable (Settings) -> Bool)? = nil,
        run: @escaping @MainActor @Sendable (CommandContext) -> Void
    ) {
        self.command = command
        self.isChecked = isChecked
        self.run = run
    }
}
