/// The one list of command sets the app registers.
public enum AppCommands {
    public static let sets: [any CommandSet.Type] = [
        NavigationCommands.self,
        SelectionCommands.self,
        ViewCommands.self,
        ColumnCommands.self,
        SystemCommands.self,
        SizeCommands.self,
        TilingCommands.self,
        DualPaneCommands.self,
        WindowCommands.self,
        FileCommands.self,
        ClipboardCommands.self,
    ]

    /// Every command in every set, with what it does.
    public static var bindings: [CommandBinding] {
        sets.flatMap { $0.bindings }
    }

    /// A registry holding every command in `sets`; throws if two share an ID or a chord. With
    /// `commanderFKeys`, the commands in `FileCommands.commanderFKeys` also take their F-key,
    /// after their own chords, so a menu still shows the first.
    public static func registry(commanderFKeys: Bool = false) throws(CommandRegistry.Conflict)
        -> CommandRegistry
    {
        var registry = CommandRegistry()
        for binding in bindings {
            let command = binding.command
            guard commanderFKeys, let fKey = FileCommands.commanderFKeys[command.id] else {
                try registry.register(command)
                continue
            }
            try registry.register(
                Command(id: command.id, title: command.title, chords: command.chords + [fKey]))
        }
        return registry
    }
}
