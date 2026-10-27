/// Undo and Redo of file changes, app-wide, through the context's `UndoHistory`. Each runs as a
/// queued operation, so the main actor never waits for one. Their menu items name the change:
/// "Undo Move 3 Items", "Undo Rename", "Undo Copy", "Undo New Folder", naming the newest
/// finished change, as in Finder; a copy still running isn't one yet. Both are off without a
/// history or a queue, with nothing to undo or redo, and while an undo or redo runs. A key
/// press doesn't check for an entry: an operation that has just ended may not be in the
/// history yet, and the history waits for it. One that then finds nothing it can undo or redo
/// beeps, as AppKit does for a key whose item is off (docs/decisions/0072-undo.md).
public enum UndoCommands: CommandSet {
    public static let undo = Command(
        id: CommandID("undo.undo"), title: "Undo",
        chords: [KeyChord("z", modifiers: .command)])
    public static let redo = Command(
        id: CommandID("undo.redo"), title: "Redo",
        chords: [KeyChord("z", modifiers: [.command, .shift])])

    // A key runs its command whether or not it is enabled; the history does nothing while busy,
    // and beeps with nothing to undo once it has caught up.
    public static var bindings: [CommandBinding] {
        [
            CommandBinding(
                undo, isEnabled: { canUndo($0) },
                title: { $0.undoHistory?.undoTitle ?? undo.title },
                run: { context in
                    guard let history = context.undoHistory, let queue = context.fileOperations
                    else { return }
                    history.undo(with: queue, nothingToDo: context.beep)
                }),
            CommandBinding(
                redo, isEnabled: { canRedo($0) },
                title: { $0.undoHistory?.redoTitle ?? redo.title },
                run: { context in
                    guard let history = context.undoHistory, let queue = context.fileOperations
                    else { return }
                    history.redo(with: queue, nothingToDo: context.beep)
                }),
        ]
    }

    /// What `operation` did, by its `record`, as the Undo and Redo items name it, after Finder:
    /// "Move 3 Items", "Rename", "Move to Trash", "Copy", or "Replace" for a copy that replaced
    /// an item, "Duplicate", "New Folder", and "Delete" for an operation that deleted an item.
    static func name(of operation: FileOperation, record: OperationRecord) -> String {
        let deletes = record.changes.contains { change in
            if case .deleted = change { true } else { false }
        }
        if deletes { return "Delete" }
        switch operation {
        case .move: return moveName(record)
        case .rename: return "Rename"
        case .trash: return FileCommands.moveToTrash.title
        case .copy:
            let replaces = record.changes.contains { change in
                if case .replaced = change { true } else { false }
            }
            return replaces ? "Replace" : "Copy"
        case .deleteImmediately: return "Delete"
        case .newFolder: return FileCommands.newFolder.title
        case .duplicate: return FileCommands.duplicate.title
        case .undo(_, let title, _): return title
        // Never run, so its record is empty and it makes no entry.
        case .receive: return "Drop"
        }
    }

    /// A move's name, "Move 3 Items", by the items `record` holds: those a move put in the
    /// folder, replacing or not, or those an undo of one took back out.
    static func moveName(_ record: OperationRecord) -> String {
        let items = record.changes.filter { change in
            switch change {
            case .moved, .created, .uncreated: true
            case .trashed, .deleted, .replaced, .putBack: false
            }
        }
        return items.count == 1 ? "Move 1 Item" : "Move \(items.count) Items"
    }

    @MainActor
    private static func canUndo(_ context: CommandContext) -> Bool {
        context.fileOperations != nil && context.undoHistory?.canUndo == true
    }

    @MainActor
    private static func canRedo(_ context: CommandContext) -> Bool {
        context.fileOperations != nil && context.undoHistory?.canRedo == true
    }
}
