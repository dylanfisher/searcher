import Base

/// Finder's tag commands: one per standard color tag (`FinderTag.all`), each adding the tag to
/// the focused pane's selection or, when every selected item has it, taking it off each, as a
/// click on the tag's dot in Finder's menus does. Each runs as a queued `toggleTag`, which reads
/// the items' tags off the main actor and makes an undo entry, "Add Tag “Red”". Off without a
/// queue, with nothing selected, and at a server, whose shares aren't changed
/// (docs/decisions/0121-tag-commands.md).
public enum TagCommands: CommandSet {
    /// The title of the File submenu that lists the commands.
    public static let menuTitle = "Tags"

    /// Each standard tag's command, in `FinderTag.all`'s order.
    public static let commands: [(tag: FinderTag, command: Command)] = FinderTag.all.map { tag in
        (
            tag,
            Command(
                id: CommandID("tag.\(tag.name.lowercased())"), title: "\(tag.name) Tag",
                chords: [])
        )
    }

    /// The command that toggles `tag`.
    public static func command(for tag: FinderTag) -> Command {
        guard let command = commands.first(where: { $0.tag == tag })?.command else {
            preconditionFailure("\(tag.name) isn't one of Finder's standard tags")
        }
        return command
    }

    // A key runs its command whether or not it is enabled, so each one checks again and does
    // nothing when it is off.
    public static var bindings: [CommandBinding] {
        commands.map { tag, command in
            CommandBinding(
                command, isEnabled: { FileCommands.canChangeSelection($0) },
                run: { context in
                    guard FileCommands.canChangeSelection(context),
                        let queue = context.fileOperations,
                        let paths = FileCommands.selectedPaths(in: context.pane)
                    else { return }
                    queue.submit(.toggleTag(tag, on: paths))
                })
        }
    }

    /// The tags of each item at `paths` that can be read, for the menu's dots to show which
    /// tags the items have. Reads on a `BlockingCallThread`, since an item on a share that
    /// stopped answering blocks the read. An item that can't be read is left out of the dots;
    /// a click's toggle reads it again and reports its error in the operations panel.
    public static func tags(of paths: [String]) async -> [[String]] {
        await BlockingCallThread.run {
            paths.compactMap { path in try? FinderTags.names(at: path) }
        }
    }
}
