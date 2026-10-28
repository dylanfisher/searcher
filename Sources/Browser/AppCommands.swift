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
        WorkspaceCommands.self,
        FileCommands.self,
        ClipboardCommands.self,
        UndoCommands.self,
    ]

    /// Every command in every set, with what it does.
    public static var bindings: [CommandBinding] {
        sets.flatMap { $0.bindings }
    }

    /// Every command in every set, with its default chords.
    public static var commands: [Command] {
        bindings.map(\.command)
    }

    /// A registry holding every command in `sets` with its default chords; throws if two share
    /// an ID or a chord.
    public static func registry() throws(CommandRegistry.Conflict) -> CommandRegistry {
        try KeyBindings(commands: commands).registry
    }

    /// The bindings `settings` asks for: every command in `sets`, with the Commander F-keys
    /// (`FileCommands.commanderFKeys`) as default alternates while `Settings.commanderFKeys` is
    /// on, the config file's `Settings.configShortcuts` over both, and `Settings.shortcuts` over
    /// those. No command takes a chord in `reserved`, and each `fixed` chord stays its command's
    /// primary. Throws only for a clash between defaults, as `registry()` does.
    @MainActor
    public static func keyBindings(
        settings: Settings, reserved: Set<KeyChord>, fixed: [KeyChord: CommandID]
    ) throws(CommandRegistry.Conflict) -> KeyBindings {
        try KeyBindings(
            commands: commands,
            preset: settings.commanderFKeys ? FileCommands.commanderFKeys : [:],
            overrides: settings.shortcuts, fileOverrides: settings.configShortcuts,
            reserved: reserved, fixed: fixed)
    }
}
