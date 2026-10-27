import Base
import Foundation

/// Changing files: Move to Trash, New Folder, Duplicate, Rename, and Copy and Move to Other
/// Pane. Each reads the focused pane's selection from `Pane` and runs through the context's
/// `FileOperationQueue`; every one is off without a queue, and those that act on the selection
/// are off with nothing selected. Copy and Move to Other Pane put the selection in the folder of
/// the selected tab's `Layout.otherPane`, only once the user confirms, and are off with one pane.
/// New Folder, Duplicate and a rename select what they made once the pane lists it, unless the
/// selection changed first (docs/decisions/0066-file-commands.md). New Folder then edits the new
/// folder's name, as Rename does (docs/decisions/0068-inline-rename.md). Once Move to Trash
/// lands, the cursor goes to the row after what it trashed, unless the selection changed first
/// (docs/decisions/0077-selection-history.md). At a server, which has no folder of its own, New
/// Folder is off unless a share's column is its target, the selected shares can't be trashed,
/// duplicated, renamed or moved, and nothing goes into another pane at a server
/// (docs/decisions/0114-server-location.md).
public enum FileCommands: CommandSet {
    public static let moveToTrash = Command(
        id: CommandID("file.moveToTrash"), title: "Move to Trash",
        chords: [KeyChord(.delete, modifiers: .command)])
    /// Makes "untitled folder", or the first free "untitled folder N", in the pane's folder, or
    /// in column view in the folder selected alone in the focused column (`destination(in:)`).
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

    /// The Commander F-key preset: the default alternate each command gets while
    /// `Settings.commanderFKeys` is on, which none has otherwise; the user's own alternate
    /// replaces it (docs/decisions/0106-primary-and-alternate-shortcuts.md). F5 and F6 ask
    /// first, as Cmd-Shift-C and M do.
    public static let commanderFKeys: [CommandID: KeyChord] = [
        copyToOtherPane.id: KeyChord(.function(5)),
        moveToOtherPane.id: KeyChord(.function(6)),
        newFolder.id: KeyChord(.function(7)),
        moveToTrash.id: KeyChord(.function(8)),
    ]

    // A key runs its command whether or not it is enabled, so each one checks again and does
    // nothing when it is off.
    public static var bindings: [CommandBinding] {
        [
            CommandBinding(
                moveToTrash, isEnabled: { canChangeSelection($0) },
                run: { context in
                    let pane = context.pane
                    guard canChangeSelection(context), let queue = context.fileOperations,
                        let paths = selectedPaths(in: pane)
                    else { return }
                    let trash = pane.moveCursorPastSelectionOnceGone()
                    let finished = queue.submit(.trash(paths))
                    Task { [weak pane] in
                        let state = await finished.value
                        pane?.trashDidFinish(trash, state)
                    }
                }),
            CommandBinding(
                newFolder, isEnabled: { $0.fileOperations != nil && hasDestinationFolder($0) },
                run: { context in
                    guard let queue = context.fileOperations else { return }
                    let pane = destination(in: context)
                    guard pane.location.isFolder else { return }
                    make(.newFolder(in: pane.location.folderPath), in: pane, queue: queue) {
                        guard selectedCount(in: pane) == 1, let editName = context.editName
                        else { return }
                        editName()
                    }
                }),
            CommandBinding(
                duplicate, isEnabled: { canChangeSelection($0) },
                run: { context in
                    let pane = context.pane
                    guard canChangeSelection(context), let queue = context.fileOperations,
                        let paths = selectedPaths(in: pane)
                    else { return }
                    run(.duplicate(paths), selectingIn: pane, queue: queue)
                }),
            CommandBinding(
                rename, isEnabled: { canRename($0) },
                run: { context in
                    guard canRename(context), let editName = context.editName else { return }
                    editName()
                }),
            CommandBinding(
                copyToOtherPane, isEnabled: { otherPaneFolder($0, moving: false) != nil },
                run: { sendToOtherPane($0, moving: false) { .copy($0, into: $1) } }),
            CommandBinding(
                moveToOtherPane, isEnabled: { otherPaneFolder($0, moving: true) != nil },
                run: { sendToOtherPane($0, moving: true) { .move($0, into: $1) } }),
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
        let state = await queue.perform(
            .rename(pane.location.folderChild(named: name).folderPath, to: newName))
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
        let finished = queue.submit(operation)
        Task { [weak pane] in
            let state = await finished.value
            pane?.select(
                names(madeBy: state.record), whenListedAtSelectionVersion: version,
                then: selected)
        }
    }

    /// The pane whose folder New Folder, Paste and Move Items Here put what they make in: in
    /// column view, the column of the folder selected alone in the focused one, as in Finder;
    /// otherwise the context's pane. Read when the command runs, so a selection made while the
    /// operation runs doesn't move it (docs/decisions/0111-column-view-target-folder.md).
    @MainActor
    static func destination(in context: CommandContext) -> Pane {
        guard let trail = context.pane.containingTrail, trail.focused.pane === context.pane else {
            return context.pane
        }
        trail.openHeldColumn()
        return trail.selectedFolderColumn ?? context.pane
    }

    /// Whether New Folder, Paste and Move Items Here have a folder to put items in: the pane's
    /// folder, or in column view a share selected alone at a server, its column shown. A server
    /// has no folder of its own to put an item in (0114-server-location.md).
    @MainActor
    static func hasDestinationFolder(_ context: CommandContext) -> Bool {
        if context.pane.location.isFolder { return true }
        guard let trail = context.pane.containingTrail, trail.focused.pane === context.pane else {
            return false
        }
        return trail.selectedFolderColumn != nil
    }

    /// Queues `operation`, which makes items in `pane`'s folder, and selects them there once the
    /// pane lists them, as `run` does. A column without the keys then takes them, as Finder
    /// moves them into the folder it pasted into; then `selected` runs. Nothing runs if the
    /// operation made nothing, the column's selection changed first or the column closed.
    @MainActor
    static func make(
        _ operation: FileOperation, in pane: Pane, queue: FileOperationQueue,
        then selected: (@MainActor () -> Void)? = nil
    ) {
        run(operation, selectingIn: pane, queue: queue) { [weak pane] in
            guard let pane else { return }
            if let trail = pane.containingTrail {
                // A column the trail closed has no keys to take, and no name field to open.
                guard let column = trail.columns.first(where: { $0.pane === pane }) else { return }
                trail.focus(column)
            }
            selected?()
        }
    }

    /// Queues `operation`, waits for it to finish and returns its last state. With a `pane`,
    /// what it made is selected there once the pane lists it, unless the selection changed
    /// first, as `run` selects. A drop passes no pane when its target isn't the pane's folder.
    @MainActor
    public static func perform(
        _ operation: FileOperation, selectingIn pane: Pane?, queue: FileOperationQueue
    ) async -> OperationState {
        let version = pane?.selectionVersion
        let state = await queue.perform(operation)
        if let pane, let version {
            pane.select(names(madeBy: state.record), whenListedAtSelectionVersion: version)
        }
        return state
    }

    /// Asks the user to confirm putting the selection in the other pane's folder, and queues it
    /// only on yes.
    @MainActor
    private static func sendToOtherPane(
        _ context: CommandContext, moving: Bool,
        _ operation: ([String], String) -> FileOperation
    ) {
        guard let folder = otherPaneFolder(context, moving: moving),
            let queue = context.fileOperations, let paths = selectedPaths(in: context.pane)
        else { return }
        let operation = operation(paths, folder)
        Task {
            guard await queue.prompts.confirm(.otherPane(operation)) else { return }
            queue.submit(operation)
        }
    }

    /// The names of the items `record` says were made or moved to, in the order made.
    private static func names(madeBy record: OperationRecord) -> [String] {
        record.changes.compactMap { change in
            switch change {
            case .created(let path, _), .moved(_, let path), .putBack(_, let path):
                lastComponent(of: path)
            case .trashed, .deleted, .replaced, .uncreated: nil
            }
        }
    }

    /// The selected entries' paths; nil when one is a server's row whose share isn't mounted
    /// where the row says, so a command refuses the selection rather than act on part of it
    /// (docs/decisions/0115-server-shares.md).
    @MainActor
    private static func selectedPaths(in pane: Pane) -> [String]? {
        var paths: [String] = []
        for entry in pane.selectedEntries {
            guard let location = pane.childLocation(of: entry) else { return nil }
            paths.append(location.folderPath)
        }
        return paths
    }

    @MainActor
    private static func selectedCount(in pane: Pane) -> Int {
        guard let listing = pane.state.listing else { return 0 }
        return pane.selection.rows(in: listing).count
    }

    /// Whether a command that acts on the selection can run: there is a queue and a selection.
    @MainActor
    private static func canTakeSelection(_ context: CommandContext) -> Bool {
        context.fileOperations != nil && selectedCount(in: context.pane) > 0
    }

    /// Whether a command that trashes, duplicates, renames or moves the selection can run: it
    /// can take the selection, and the pane is at a folder. A server's shares can't be changed
    /// so (0114-server-location.md).
    @MainActor
    private static func canChangeSelection(_ context: CommandContext) -> Bool {
        context.pane.location.isFolder && canTakeSelection(context)
    }

    @MainActor
    private static func canRename(_ context: CommandContext) -> Bool {
        context.pane.location.isFolder && context.fileOperations != nil
            && context.editName != nil && selectedCount(in: context.pane) == 1
    }

    /// The path of the selected tab's other pane's folder, when there is one, a queue and a
    /// selection, and the selection can move when `moving`. Nil when the other pane is at a
    /// server, which has no folder to put items in (0114-server-location.md).
    @MainActor
    private static func otherPaneFolder(_ context: CommandContext, moving: Bool) -> String? {
        guard moving ? canChangeSelection(context) : canTakeSelection(context),
            let id = context.tab.layout.otherPane, let other = context.tab.panes[id],
            other.location.isFolder
        else { return nil }
        return other.location.folderPath
    }
}
