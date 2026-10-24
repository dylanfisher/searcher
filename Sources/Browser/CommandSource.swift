/// The registry's commands as palette items, in the order registered, each with its first
/// chord. A sync source: it reads the registry on every key.
@MainActor
public struct CommandSource: PaletteSource {
    private let registry: @MainActor () -> CommandRegistry
    private let run: @MainActor @Sendable (CommandID) -> Void

    /// `registry` gives the commands as they are now; `run` runs one by its ID, as its key would.
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
            registry().commands.map { command in
                PaletteItem(
                    id: .command(command.id), title: command.title, chord: command.chords.first
                ) { run(command.id) }
            })
    }

    public func cancel() {}
}
