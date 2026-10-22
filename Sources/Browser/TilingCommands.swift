/// The tiling keys: split, focus, move and resize panes, zoom one, equalize them, and close one,
/// all on the selected tab of the context's workspace. They change the model only; the window
/// shows the result. Split, focus and move end a zoom before they act, even when they then find
/// nothing to do.
///
/// Not in `AppCommands.sets` yet: the panes' views build their contexts without a workspace,
/// and the window shows one pane (docs/decisions/0044-tiling-commands.md).
public enum TilingCommands: CommandSet {
    /// How far one resize key moves a split, in points. The divider's VoiceOver increment uses it
    /// too.
    public static let resizeStep = 40.0

    public static let splitRight = Command(
        id: CommandID("tiling.splitRight"), title: "Split Right",
        chords: [KeyChord("\\", modifiers: .command)])
    public static let splitDown = Command(
        id: CommandID("tiling.splitDown"), title: "Split Down",
        chords: [KeyChord("\\", modifiers: [.command, .shift])])
    public static let focus = commands(
        "focus", title: "Focus Pane", modifiers: [.command, .option])
    public static let move = commands(
        "move", title: "Move Pane", modifiers: [.command, .option, .shift])
    public static let resize = commands(
        "resize", title: "Resize Pane", modifiers: [.control, .command])
    public static let zoom = Command(
        id: CommandID("tiling.zoom"), title: "Zoom Pane",
        chords: [KeyChord(.return, modifiers: [.command, .shift])])
    public static let equalize = Command(
        id: CommandID("tiling.equalize"), title: "Equalize Panes",
        chords: [KeyChord("0", modifiers: [.command, .option])])
    /// Closes the focused pane, and the tab with its last pane. The context's `didClosePane`
    /// gets what closed; closing the tab's view or the window is the window's job.
    public static let closePane = Command(
        id: CommandID("tiling.closePane"), title: "Close Pane",
        chords: [KeyChord("w", modifiers: .command)])

    public static var bindings: [CommandBinding] {
        [
            CommandBinding(splitRight) { split(.horizontal, in: $0) },
            CommandBinding(splitDown) { split(.vertical, in: $0) },
        ]
            + Direction.allCases.map { direction in
                CommandBinding(command(focus, direction)) { unzoomed($0.tab).focus(direction) }
            }
            + Direction.allCases.map { direction in
                CommandBinding(command(move, direction)) { unzoomed($0.tab).move(direction) }
            }
            + Direction.allCases.map { direction in
                CommandBinding(command(resize, direction)) { context in
                    context.tab.resize(direction, by: resizeStep, in: context.tabBounds())
                }
            }
            + [
                CommandBinding(zoom) { $0.tab.toggleZoom() },
                CommandBinding(equalize) { $0.tab.equalize(in: $0.tabBounds()) },
                CommandBinding(closePane) { $0.didClosePane($0.workspace.closePane()) },
            ]
    }

    @MainActor
    private static func split(_ axis: Axis, in context: CommandContext) {
        unzoomed(context.tab).split(axis, in: context.tabBounds())
    }

    @MainActor
    private static func unzoomed(_ tab: Tab) -> Tab {
        if tab.layout.isZoomed {
            tab.toggleZoom()
        }
        return tab
    }

    /// One command per direction, bound to that arrow with `modifiers`, such as
    /// "tiling.focusLeft", "Focus Pane Left".
    private static func commands(
        _ verb: String, title: String, modifiers: KeyChord.Modifiers
    ) -> [Direction: Command] {
        Dictionary(
            uniqueKeysWithValues: Direction.allCases.map { direction in
                let name = "\(direction)"
                let command = Command(
                    id: CommandID(
                        "tiling.\(verb)\(name.prefix(1).uppercased())\(name.dropFirst())"),
                    title: "\(title) \(name.prefix(1).uppercased())\(name.dropFirst())",
                    chords: [KeyChord(arrow(direction), modifiers: modifiers)])
                return (direction, command)
            })
    }

    private static func command(_ commands: [Direction: Command], _ direction: Direction) -> Command
    {
        guard let command = commands[direction] else {
            preconditionFailure("no tiling command for \(direction)")
        }
        return command
    }

    private static func arrow(_ direction: Direction) -> KeyChord.Key {
        switch direction {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        }
    }
}
