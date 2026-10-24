/// The registry's commands as palette items, in the order registered, each with its first
/// chord, but for `unlisted`. A sync source: it reads the registry on every key.
@MainActor
public struct CommandSource: PaletteSource {
    private let registry: @MainActor () -> CommandRegistry
    private let run: @MainActor @Sendable (CommandID) -> Void

    /// `registry` gives the commands as they are now; `run` runs one by its ID, as its key would.
    /// The commands that can't run from the palette, which it leaves out: Open in New Tab, which
    /// needs a clicked folder; Open Quickly, which shows the palette itself; and the row keys,
    /// which move a selection the palette covers while it shows.
    public static let unlisted: Set<CommandID> = Set(
        [
            WindowCommands.openInNewTab, WindowCommands.showPalette,
            SelectionCommands.selectNext, SelectionCommands.selectPrevious,
            SelectionCommands.selectFirst, SelectionCommands.selectLast,
            SelectionCommands.extendDown, SelectionCommands.extendUp,
            SelectionCommands.tenRowsDown, SelectionCommands.tenRowsUp,
            SelectionCommands.pageDown, SelectionCommands.pageUp,
        ].map(\.id))

    public init(
        registry: @escaping @MainActor () -> CommandRegistry,
        run: @escaping @MainActor @Sendable (CommandID) -> Void
    ) {
        self.registry = registry
        self.run = run
    }

    public func gather(_ query: String, deliver: @escaping @MainActor ([PaletteItem]) -> Void) {
        let run = run
        deliver(
            registry().commands.filter { !Self.unlisted.contains($0.id) }.map { command in
                PaletteItem(
                    id: .command(command.id), title: command.title, chord: command.chords.first
                ) { run(command.id) }
            })
    }

    public func cancel() {}
}
