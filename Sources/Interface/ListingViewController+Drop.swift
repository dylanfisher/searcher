import AppKit
import Base
import Browser
import UniformTypeIdentifiers

extension ListingViewController {
    /// What a drag of rows lets its destination do with them.
    static let dragOperations: NSDragOperation = [.copy, .move, .generic, .link]

    /// A row drags out as its file URL, a folder's ending in a slash, built from the listing
    /// without reading the disk (docs/decisions/0071-drag-and-drop.md). A selected row drags with
    /// the selection, so none of it drags while the selection holds a server's row with no
    /// location, rather than part of it (docs/decisions/0115-server-shares.md).
    public func tableView(
        _ tableView: NSTableView, pasteboardWriterForRow row: Int
    ) -> (any NSPasteboardWriting)? {
        guard let listing, row >= 0, row < listing.count,
            !(pane.selectsUnmountedShare && pane.selection.contains(ExactName(listing[row].name))),
            let url = ClipboardCommands.fileURL(of: listing[row], in: pane)
        else { return nil }
        return PasteboardFileClipboard.item(for: url)
    }

    /// What a drop does where it is: into the folder of a folder row it is on, to the app of an
    /// app's row, which opens the files, else into the pane's folder, for which the whole list is
    /// highlighted; a package that isn't an app takes nothing, as a file doesn't. Reads only the
    /// drag's pasteboard, the listing and the mount table, so it makes no file-system call.
    public func tableView(
        _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        let drop = drop(info, row: row, dropOperation)
        springLoader?.hover(
            over: drop?.folderRow.map {
                SpringLoader.Target(pane: pane, location: pane.location, name: $0)
            }, info: info)
        guard let drop else { return [] }
        if drop.pane != nil, row != -1 || dropOperation != .on {
            tableView.setDropRow(-1, dropOperation: .on)
        }
        switch drop.content {
        case .files(_, let operation):
            return operation.dragOperation(allowed: info.draggingSourceOperationMask)
        case .promises:
            return .copy
        case .open:
            return .generic
        }
    }

    /// Queues the drop's one copy, move or duplicate, without asking first, as Paste does; or
    /// takes its file promises. What lands in the pane's folder is selected once the pane lists
    /// it.
    public func tableView(
        _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let queue = fileOperations, let drop = drop(info, row: row, dropOperation) else {
            return false
        }
        // The drop's operations are listed in the window it landed in.
        let workspace = workspaceID
        switch drop.content {
        case .files(let paths, let operation):
            let operation = operation.fileOperation(paths, into: drop.folder)
            Task { [pane = drop.pane] in
                await FileOperationQueue.$workspace.withValue(workspace) {
                    _ = await FileCommands.perform(operation, selectingIn: pane, queue: queue)
                }
            }
        case .promises:
            guard
                let promises = info.draggingPasteboard.readObjects(
                    forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
                !promises.isEmpty
            else {
                preconditionFailure("a drop that offered file promises has none to read")
            }
            // A drag leaves the app it came from active, so that names the source.
            let app = NSWorkspace.shared.frontmostApplication?.localizedName
            Task { [pane = drop.pane, folder = drop.folder] in
                await FileOperationQueue.$workspace.withValue(workspace) {
                    await FilePromiseReceiver.receive(
                        promises, into: folder, from: app, selectingIn: pane, queue: queue)
                }
            }
        case .open(let urls, let application):
            pane.systemActions.open(urls, withApplicationAt: application)
        }
        return true
    }

    /// A drop the list takes: the folder it goes into, the pane when that is the pane's folder,
    /// the folder row's name when it goes into one, which springs open while the drag hovers,
    /// and what it carries.
    private struct Drop {
        enum Content {
            /// File URLs' paths, and whether they copy or move.
            case files([String], DropOperation)
            /// File promises, which always copy.
            case promises
            /// File URLs dropped on the app at a URL, which opens them.
            case open([URL], withApplicationAt: URL)
        }

        let folder: String
        let pane: Pane?
        var folderRow: String?
        let content: Content
    }

    /// The drop `info` makes at `row` with `dropOperation`, or nil when the list takes none
    /// there. File URLs are read first; a drag with none is taken for its file promises.
    private func drop(
        _ info: any NSDraggingInfo, row: Int, _ dropOperation: NSTableView.DropOperation
    ) -> Drop? {
        guard fileOperations != nil, let mountTable else { return nil }
        var folder = pane.location
        var target: Pane? = pane
        var app: Location?
        var folderRow: String?
        if dropOperation == .on, let listing, row >= 0, row < listing.count {
            let kind = listing.kind(atRow: row).type
            if kind == .folder {
                // A server's row whose share isn't mounted where it says takes no drop.
                guard let child = pane.childLocation(of: listing[row]) else { return nil }
                folder = child
                target = nil
                folderRow = listing[row].name
            } else if listing[row].type == .package, kind.conforms(to: .application) {
                app = pane.location.folderChild(named: listing[row].name)
            }
        }
        // A server has no folder to drop into; a share row is one (0114-server-location.md).
        guard folder.isFolder else { return nil }
        let pasteboard = info.draggingPasteboard
        let urls = PasteboardFileClipboard(pasteboard: pasteboard).fileURLs()
        let paths = urls.map(\.path)
        if let app {
            // Files dropped on an app open with it, as in Finder; nothing goes into the app.
            guard !paths.isEmpty, !paths.contains(app.folderPath) else { return nil }
            let application = URL(fileURLWithPath: app.folderPath, isDirectory: true)
            return Drop(
                folder: folder.folderPath, pane: nil,
                content: .open(urls, withApplicationAt: application)
            )
        }
        if !paths.isEmpty {
            guard
                let operation = DropOperation(
                    dropping: paths, into: folder.folderPath,
                    allowed: info.draggingSourceOperationMask, mounts: mountTable)
            else { return nil }
            return Drop(
                folder: folder.folderPath, pane: target, folderRow: folderRow,
                content: .files(paths, operation))
        }
        guard pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self]),
            info.draggingSourceOperationMask.contains(.copy)
        else { return nil }
        return Drop(
            folder: folder.folderPath, pane: target, folderRow: folderRow, content: .promises)
    }
}
