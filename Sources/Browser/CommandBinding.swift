/// A command and what it does when it runs.
public struct CommandBinding: Sendable {
    public let command: Command
    public let run: @MainActor @Sendable (CommandContext) -> Void

    public init(_ command: Command, run: @escaping @MainActor @Sendable (CommandContext) -> Void) {
        self.command = command
        self.run = run
    }
}
