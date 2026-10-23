/// A command and what it does when it runs.
public struct CommandBinding: Sendable {
    public let command: Command
    public let run: @MainActor @Sendable (CommandContext) -> Void
    /// For a command that turns a setting on and off: whether it is on, which its menu item shows
    /// as a check mark. Nil for other commands.
    public let isChecked: (@MainActor @Sendable (Settings) -> Bool)?
    /// For a command that puts the pane in one of several modes, such as "as Columns": whether
    /// the pane is in that mode, which its menu item shows as a check mark. Nil for other
    /// commands.
    public let isCurrent: (@MainActor @Sendable (CommandContext) -> Bool)?
    /// For a command that does nothing in some states, such as Back with no folder to go back to:
    /// whether it would do something, which its menu item shows by being enabled. Nil for
    /// commands that can always run.
    public let isEnabled: (@MainActor @Sendable (CommandContext) -> Bool)?
    /// For a command whose menu item names what it would do, such as "Undo Move 3 Items": the
    /// item's title now. Nil for commands whose item shows `command.title`.
    public let title: (@MainActor @Sendable (CommandContext) -> String)?

    public init(
        _ command: Command, isChecked: (@MainActor @Sendable (Settings) -> Bool)? = nil,
        isCurrent: (@MainActor @Sendable (CommandContext) -> Bool)? = nil,
        isEnabled: (@MainActor @Sendable (CommandContext) -> Bool)? = nil,
        title: (@MainActor @Sendable (CommandContext) -> String)? = nil,
        run: @escaping @MainActor @Sendable (CommandContext) -> Void
    ) {
        self.command = command
        self.isChecked = isChecked
        self.isCurrent = isCurrent
        self.isEnabled = isEnabled
        self.title = title
        self.run = run
    }
}
