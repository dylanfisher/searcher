/// The one list of command sets the app registers.
public enum AppCommands {
    public static let sets: [any CommandSet.Type] = [
        NavigationCommands.self,
        SelectionCommands.self,
        ViewCommands.self,
        ColumnCommands.self,
        SystemCommands.self,
    ]

    /// Every command in every set, with what it does.
    public static var bindings: [CommandBinding] {
        sets.flatMap { $0.bindings }
    }

    /// A registry holding every command in `sets`; throws if two share an ID or a chord.
    public static func registry() throws(CommandRegistry.Conflict) -> CommandRegistry {
        var registry = CommandRegistry()
        for binding in bindings {
            try registry.register(binding.command)
        }
        return registry
    }
}
