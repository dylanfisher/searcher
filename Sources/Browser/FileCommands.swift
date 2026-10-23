import Foundation

/// Changing files: Move to Trash, New Folder, Duplicate, Rename, and Copy and Move to Other
/// Pane. Each reads the focused pane's selection from `Pane` and runs through the context's
/// `FileOperationQueue`; every one is off without a queue, and those that act on the selection
/// are off with nothing selected. Copy and Move to Other Pane put the selection in the folder of
/// the selected tab's `Layout.otherPane`, only once the user confirms, and are off with one pane.
/// New Folder, Duplicate and a rename select what they made once the pane lists it, unless the
/// selection changed first (docs/decisions/0066-file-commands.md). New Folder then edits the new
/// folder's name, as Rename does (docs/decisions/0068-inline-rename.md).
public enum FileCommands: CommandSet {
    public static let moveToTrash = Command(
        id: CommandID("file.moveToTrash"), title: "Move to Trash",
        chords: [KeyChord(.delete, modifiers: .command)])
    /// Makes "untitled folder", or the first free "untitled folder N", in the pane's folder.
    public static let newFolder = Command(
        id: CommandID("file.newFolder"), title: "New Folder",
        chords: [KeyChord("n", modifiers: [.command, .shift])])
    /// Copies each selected entry beside itself with Finder's duplicate name.
    public static let duplicate = Command(
        id: CommandID("file.duplicate"), title: "Duplicate",
        chords: [KeyChord("d", modifiers: .command)])
    /// Edits the one selected entry's name in place; the view commits it with
    /// `rename(_:to:in:queue:)`.
    public static let rename = Command(
        id: CommandID("file.rename"), title: "Rename", chords: [KeyChord(.return)])
    public static let copyToOtherPane = Command(
        id: CommandID("file.copyToOtherPane"), title: "Copy to Other Pane",
        chords: [KeyChord("c", modifiers: [.command, .shift])])
    public static let moveToOtherPane = Command(
        id: CommandID("file.moveToOtherPane"), title: "Move to Other Pane",
        chords: [KeyChord("m", modifiers: [.command, .shift])])

    // A key runs its command whether or not it is enabled, so each one checks again and does
    // nothing when it is off.
    public static var bindings: [CommandBinding] {
        [
            CommandBinding(
                moveToTrash, isEnabled: { canChangeSelection($0) },
                run: { context in
                    guard canChangeSelection(context), let queue = context.fileOperations else {
                        return
                    }
                    let operation = FileOperation.trash(selectedPaths(in: context.pane))
                    Task { await queue.enqueue(operation) }
                }),
            CommandBinding(
                newFolder, isEnabled: { $0.fileOperations != nil },
                run: { context in
                    guard let queue = context.fileOperations else { return }
                    let pane = context.pane
                    run(.newFolder(in: pane.location.path), selectingIn: pane, queue: queue) {
                        guard canRename(context), let editName = context.editName else { return }
                        editName()
                    }
                }),
            CommandBinding(
                duplicate, isEnabled: { canChangeSelection($0) },
                run: { context in
                    guard canChangeSelection(context), let queue = context.fileOperations else {
                        return
                    }
                    let pane = context.pane
                    run(.duplicate(selectedPaths(in: pane)), selectingIn: pane, queue: queue)
                }),
            CommandBinding(
                rename, isEnabled: { canRename($0) },
                run: { context in
                    guard canRename(context), let editName = context.editName else { return }
                    editName()
                }),
            CommandBinding(
                copyToOtherPane, isEnabled: { otherPaneFolder($0) != nil },
                run: { sendToOtherPane($0) { .copy($0, into: $1) } }),
            CommandBinding(
                moveToOtherPane, isEnabled: { otherPaneFolder($0) != nil },
                run: { sendToOtherPane($0) { .move($0, into: $1) } }),
        ]
    }

    /// Renames the entry `name` in `pane`'s folder to `newName` through `queue`, and returns the
    /// operation's last state, whose errors say why a rename failed. The entry is selected under
    /// its new name once the pane lists it, unless the selection changed first.
    @MainActor
    public static func rename(
        _ name: String, to newName: String, in pane: Pane, queue: FileOperationQueue
    ) async -> OperationState {
        let version = pane.selectionVersion
        let state = await queue.perform(.rename(pane.location.child(named: name).path, to: newName))
        pane.select(names(madeBy: state.record), whenListedAtSelectionVersion: version)
        return state
    }

    /// Queues `operation` and selects what it made in `pane` once the pane lists it, then runs
    /// `selected`. Nothing runs if it made nothing or the selection changed first.
    @MainActor
    static func run(
        _ operation: FileOperation, selectingIn pane: Pane, queue: FileOperationQueue,
        then selected: (@MainActor () -> Void)? = nil
    ) {
        let version = pane.selectionVersion
        Task { [weak pane] in
            let state = await queue.perform(operation)
            pane?.select(
                names(madeBy: state.record), whenListedAtSelectionVersion: version,
                then: selected)
        }
    }

    /// Asks the user to confirm putting the selection in the other pane's folder, and queues it
    /// only on yes.
    @MainActor
    private static func sendToOtherPane(
        _ context: CommandContext, _ operation: ([String], String) -> FileOperation
    ) {
        guard let folder = otherPaneFolder(context), let queue = context.fileOperations else {
            return
        }
        let operation = operation(selectedPaths(in: context.pane), folder.path)
        Task {
            guard await queue.prompts.confirm(.otherPane(operation)) else { return }
            await queue.enqueue(operation)
        }
    }

    /// The names of the items `record` says were made or moved to, in the order made.
    private static func names(madeBy record: OperationRecord) -> [String] {
        record.changes.compactMap { change in
            switch change {
            case .created(let path), .moved(_, let path): (path as NSString).lastPathComponent
            case .trashed, .deleted, .replaced: nil
            }
        }
    }

    @MainActor
    static func selectedPaths(in pane: Pane) -> [String] {
        pane.selectedEntries.map { pane.location.child(named: $0.name).path }
    }

    @MainActor
    private static func selectedCount(in pane: Pane) -> Int {
        guard let listing = pane.state.listing else { return 0 }
        return pane.selection.rows(in: listing).count
    }

    /// Whether a command that acts on the selection can run: there is a queue and a selection.
    @MainActor
    private static func canChangeSelection(_ context: CommandContext) -> Bool {
        context.fileOperations != nil && selectedCount(in: context.pane) > 0
    }

    @MainActor
    private static func canRename(_ context: CommandContext) -> Bool {
        context.fileOperations != nil && context.editName != nil
            && selectedCount(in: context.pane) == 1
    }

    /// The folder of the selected tab's other pane, when there is one, a queue and a selection.
    @MainActor
    private static func otherPaneFolder(_ context: CommandContext) -> Location? {
        guard canChangeSelection(context), let id = context.tab.layout.otherPane,
            let other = context.tab.panes[id]
        else { return nil }
        return other.location
    }
}
