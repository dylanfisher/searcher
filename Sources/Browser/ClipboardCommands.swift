import Base
import Foundation

/// Cut, Copy and Paste of files, through the context's `CutState`. Copy and Cut put the focused
/// pane's selection on the clipboard as file URLs; Cut also marks it cut. Paste puts what the
/// clipboard holds in the pane's folder, or in column view in the folder selected alone in the
/// focused column (docs/decisions/0111-column-view-target-folder.md): it moves the files of a
/// cut that is still on the clipboard and copies anything else, Finder's files included. Move
/// Items Here always moves. Neither asks first. Pasted items are selected as Duplicate's copies
/// are, and no name is edited (docs/decisions/0069-cut-and-paste.md). Every command is off
/// without a clipboard, and the pastes are off without a queue or with no files on the
/// clipboard.
public enum ClipboardCommands: CommandSet {
    public static let copy = Command(
        id: CommandID("clipboard.copy"), title: "Copy",
        chords: [KeyChord("c", modifiers: .command)])
    public static let cut = Command(
        id: CommandID("clipboard.cut"), title: "Cut",
        chords: [KeyChord("x", modifiers: .command)])
    public static let paste = Command(
        id: CommandID("clipboard.paste"), title: "Paste",
        chords: [KeyChord("v", modifiers: .command)])
    /// Moves the files on the clipboard into the pane's folder, whether or not they were cut. In
    /// column view, as Paste, it moves them into the folder selected alone in the focused column.
    public static let moveHere = Command(
        id: CommandID("clipboard.moveHere"), title: "Move Items Here",
        chords: [KeyChord("v", modifiers: [.command, .option])])

    // A key runs its command whether or not it is enabled, so each one checks again and does
    // nothing when it is off.
    public static var bindings: [CommandBinding] {
        [
            CommandBinding(
                copy, isEnabled: { canTakeSelection($0) },
                run: { context in
                    guard canTakeSelection(context), let clipboard = context.clipboard else {
                        return
                    }
                    clipboard.copy(selectedURLs(in: context.pane))
                }),
            CommandBinding(
                cut, isEnabled: { canTakeSelection($0) },
                run: { context in
                    guard canTakeSelection(context), let clipboard = context.clipboard else {
                        return
                    }
                    clipboard.cut(selectedURLs(in: context.pane))
                }),
            CommandBinding(
                paste, isEnabled: { canPaste($0) },
                run: { pasteFiles($0, alwaysMoving: false) }),
            CommandBinding(
                moveHere, isEnabled: { canPaste($0) },
                run: { pasteFiles($0, alwaysMoving: true) }),
        ]
    }

    /// Puts the clipboard's files in the pane's folder, or in column view in the folder selected
    /// alone in the focused column (`FileCommands.destination(in:)`): a move for a cut still on
    /// the clipboard or when `alwaysMoving`, else a copy. A move ends the cut, so a second Paste
    /// copies.
    @MainActor
    private static func pasteFiles(_ context: CommandContext, alwaysMoving: Bool) {
        guard canPaste(context), let clipboard = context.clipboard,
            let queue = context.fileOperations
        else { return }
        let isCut = clipboard.cutPaths != nil
        let paths = clipboard.clipboard.fileURLs().map(\.path)
        if isCut || alwaysMoving {
            clipboard.clear()
        }
        let pane = FileCommands.destination(in: context)
        let folder = pane.location.folderPath
        let operation: FileOperation =
            isCut || alwaysMoving ? .move(paths, into: folder) : .copy(paths, into: folder)
        FileCommands.make(operation, in: pane, queue: queue)
    }

    /// The selected entries' file URLs. Each says whether it is a folder, from the listing, so
    /// building it reads nothing from the disk; a folder's ends in a slash, as Finder writes it.
    /// The list's services take these too.
    @MainActor
    public static func selectedURLs(in pane: Pane) -> [URL] {
        pane.selectedEntries.map { fileURL(of: $0, in: pane.location) }
    }

    /// The file URL of `entry` in `folder`, built as `selectedURLs` builds each one. A row
    /// dragged from a list takes it too.
    public static func fileURL(of entry: DirectoryEntry, in folder: Location) -> URL {
        URL(
            fileURLWithPath: folder.child(named: entry.name).folderPath,
            isDirectory: entry.type.isFolderOnDisk)
    }

    /// Whether Copy and Cut can run: there is a clipboard and a selection.
    @MainActor
    private static func canTakeSelection(_ context: CommandContext) -> Bool {
        guard context.clipboard != nil, let listing = context.pane.state.listing else {
            return false
        }
        return !context.pane.selection.rows(in: listing).isEmpty
    }

    /// Whether a paste can run: there is a clipboard holding files, and a queue.
    @MainActor
    private static func canPaste(_ context: CommandContext) -> Bool {
        guard let clipboard = context.clipboard, context.fileOperations != nil else {
            return false
        }
        return !clipboard.clipboard.fileURLs().isEmpty
    }
}
