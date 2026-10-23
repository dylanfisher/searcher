/// The tiling keys: split, focus, move and resize panes, set the grid's columns and rows, zoom
/// one, equalize them, and close one, all on the selected tab of the context's workspace. They
/// change the model only; the window shows the result. Split, the grid keys, focus and move end
/// a zoom before they act, even when they then find nothing to do
/// (docs/decisions/0044-tiling-commands.md, docs/decisions/0061-split-keys-and-grid-layouts.md).
public enum TilingCommands: CommandSet {
    /// How far one resize key moves a split, in points. The divider's VoiceOver increment uses it
    /// too.
    public static let resizeStep = 40.0

    /// On T, beside New Tab: the backslash key is 1Password's autofill.
    public static let splitRight = Command(
        id: CommandID("tiling.splitRight"), title: "Split Right",
        chords: [KeyChord("t", modifiers: [.command, .shift])])
    public static let splitDown = Command(
        id: CommandID("tiling.splitDown"), title: "Split Down",
        chords: [KeyChord("t", modifiers: [.option, .shift])])
    /// What each direction's title in a family starts with, such as "Focus Pane" for "Focus
    /// Pane Left", and the title of the Window submenu that lists the family.
    public static let focusTitle = "Focus Pane"
    public static let moveTitle = "Move Pane"
    public static let resizeTitle = "Resize Pane"

    public static let focus = commands(
        "focus", title: focusTitle, modifiers: [.command, .option, .shift])
    public static let move = commands(
        "move", title: moveTitle, modifiers: [.control, .option, .shift])
    public static let resize = commands(
        "resize", title: resizeTitle, modifiers: [.control, .command])
    /// The most columns or rows a grid key sets.
    public static let gridLimit = 4
    /// The titles of the Window submenus that list the grid keys.
    public static let columnsTitle = "Columns"
    public static let rowsTitle = "Rows"
    /// Cmd-Opt-1 to 4: that many panes side by side in every row, keeping the rows.
    public static let columns = gridCommands(
        "columns", one: "Column", many: columnsTitle, modifiers: [.command, .option])
    /// Cmd-Opt-Shift-1 to 4: that many panes stacked in every column, keeping the columns.
    public static let rows = gridCommands(
        "rows", one: "Row", many: rowsTitle, modifiers: [.command, .option, .shift])
    public static let zoom = Command(
        id: CommandID("tiling.zoom"), title: "Zoom Pane",
        chords: [KeyChord("z", modifiers: [.command, .option, .shift])])
    /// Only ends a zoom, so a key can show every pane again without toggling one into view. Off
    /// while the tab isn't zoomed.
    public static let unzoom = Command(
        id: CommandID("tiling.unzoom"), title: "Unzoom Pane",
        chords: [KeyChord("a", modifiers: [.command, .option, .shift])])
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
            + (1...gridLimit).map { count in
                CommandBinding(gridCommand(columns, count)) { context in
                    grid(columns: count, rows: context.tab.layout.rowCount, in: context)
                }
            }
            + (1...gridLimit).map { count in
                CommandBinding(gridCommand(rows, count)) { context in
                    grid(columns: context.tab.layout.columnCount, rows: count, in: context)
                }
            }
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
                CommandBinding(
                    unzoom, isEnabled: { $0.tab.layout.isZoomed },
                    run: { _ = unzoomed($0.tab) }),
                CommandBinding(equalize) { $0.tab.equalize(in: $0.tabBounds()) },
                CommandBinding(closePane) { $0.didClosePane($0.workspace.closePane()) },
            ]
    }

    @MainActor
    private static func split(_ axis: Axis, in context: CommandContext) {
        unzoomed(context.tab).split(axis, in: context.tabBounds())
    }

    /// Makes the tab an even grid; does nothing when a pane would be under the minimum size.
    @MainActor
    private static func grid(columns: Int, rows: Int, in context: CommandContext) {
        unzoomed(context.tab).makeGrid(columns: columns, rows: rows, in: context.tabBounds())
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

    /// One command per count from 1 to `gridLimit`, bound to that digit with `modifiers`, such as
    /// "tiling.columns2", "2 Columns".
    private static func gridCommands(
        _ name: String, one: String, many: String, modifiers: KeyChord.Modifiers
    ) -> [Int: Command] {
        Dictionary(
            uniqueKeysWithValues: (1...gridLimit).map { count in
                let command = Command(
                    id: CommandID("tiling.\(name)\(count)"),
                    title: "\(count) \(count == 1 ? one : many)",
                    chords: [KeyChord(.character(Character("\(count)")), modifiers: modifiers)])
                return (count, command)
            })
    }

    private static func gridCommand(_ commands: [Int: Command], _ count: Int) -> Command {
        guard let command = commands[count] else {
            preconditionFailure("no grid command for \(count)")
        }
        return command
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
