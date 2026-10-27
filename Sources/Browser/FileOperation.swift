import Base
import Foundation

/// A change to files that `FileOperationQueue` runs. Paths are absolute.
public enum FileOperation: Equatable, Sendable {
    /// Copies each item into the folder under its own name.
    case copy([String], into: String)
    /// Moves each item into the folder under its own name: a rename on one volume, a copy and
    /// then a delete of the source across volumes.
    case move([String], into: String)
    case trash([String])
    /// Gives the item a new name in the same folder.
    case rename(String, to: String)
    /// Makes "untitled folder", or the first free "untitled folder N", in the folder.
    case newFolder(in: String)
    /// Copies each item beside itself with Finder's duplicate name, "name copy.ext".
    case duplicate([String])
    /// Deletes each item without the Trash. Issued only after the user answered a
    /// delete-immediately question.
    case deleteImmediately([String])
    /// Files a drop promised into the folder: the source app writes them and a `move` puts them
    /// in place. `name` is the file's when one file is meant, and `app` the app the drop came
    /// from when known. The queue never runs it; it only shows one that failed
    /// (`FileOperationQueue.report`).
    case receive(name: String?, app: String?, into: String)
    /// Reverses `record`'s changes, last first (`UndoStep`), after checking that every item is
    /// where the record left it; if one isn't, nothing is changed. Redo is the undo of an
    /// undo's record. `title` names it in the operations panel, as the Edit menu did.
    /// `isRetry` says its entry was kept once after a failure that can clear, so failing again
    /// drops it (`dropsUndoEntry`, docs/decisions/0072-undo.md).
    case undo(OperationRecord, title: String, isRetry: Bool)

    /// Whether the history drops the entry `operation`, an undo, reversed once it ended in
    /// `state`: it failed and changed nothing, and either this was the entry's second try or
    /// a failure can't clear (`canClear`).
    public static func dropsUndoEntry(_ operation: FileOperation, after state: OperationState)
        -> Bool
    {
        guard case .undo(let record, _, let isRetry) = operation, state.phase == .failed,
            state.record.changes.isEmpty
        else { return false }
        return isRetry || !canClear(state.errors, undoing: record)
    }

    /// Whether every error in `errors`, from an undo of `record`, can clear without the user
    /// losing an item: a missing folder outside the items, as a drive that isn't mounted, which
    /// the check names when an item's folder is gone too; a volume that went away or stopped
    /// answering; an item in the way (`exists`); or another item where the recorded one was
    /// (`notTheSameItem`), as after a save that replaced it. The check runs again on the next
    /// try, so a kept entry never acts on another item.
    static func canClear(_ errors: [FileOperationError], undoing record: OperationRecord) -> Bool {
        let items = Set(
            steps(undoing: record).flatMap { [$0.source, $0.destination].compactMap { $0 } }
                .map(comparable))
        return !errors.isEmpty
            && errors.allSatisfy { error in
                switch error.reason {
                case .exists, .notTheSameItem, .unreachable: true
                case .sourceGone: !items.contains(comparable(error.path))
                case .noSpace, .permissionDenied, .crossVolume, .noTrash, .invalidName,
                    .changedDuringMove, .other:
                    false
                }
            }
    }

    /// One change an undo reverses.
    enum UndoStep: Equatable, Sendable {
        /// Moves the item at `from` to the path `to`, which must be free.
        case move(from: String, to: String)
        /// Moves the item in the Trash at the URL back to the path, which must be free.
        case putBack(URL, to: String)
        /// Moves the item at the path, which an undo put back, to its volume's Trash.
        case trash(String)
        /// Moves the item at the path, which the origin made, to its volume's Trash.
        case unmake(String, from: OperationRecord.Origin)
        /// Makes the item at the path, which must be free, again: copies the origin's source
        /// to it, or makes an empty folder there.
        case make(String, from: OperationRecord.Origin)

        /// The item the step changes or, for a copy it makes again, reads; nil for a new
        /// folder it makes again.
        var source: String? {
            switch self {
            case .move(let from, _): from
            case .putBack(let url, _): url.path
            case .trash(let path), .unmake(let path, _): path
            case .make(_, .copy(let source)): source
            case .make(_, .newFolder), .make(_, .drop): nil
            }
        }

        /// Whether the step only reads its source: a copy made again.
        var readsSource: Bool {
            if case .make = self { true } else { false }
        }

        var destination: String? {
            switch self {
            case .move(_, let to), .putBack(_, let to), .make(let to, _): to
            case .trash, .unmake: nil
            }
        }
    }

    /// The steps that reverse `record`, last change first: a moved item moves back, a trashed
    /// or replaced one comes back from the Trash, and an item a copy, a new folder or a drop
    /// made, or an undo put back, goes to the Trash. An item an undo took away is made again
    /// as it was made the first time, a copy from its source and a new folder empty; a drop's
    /// file comes back from the Trash, since its app can't be asked again. A replace is listed
    /// before the change that put the new item at its path, so the new item leaves before the
    /// original comes back.
    static func steps(undoing record: OperationRecord) -> [UndoStep] {
        record.changes.reversed().map { change in
            switch change {
            case .created(let path, let origin): .unmake(path, from: origin)
            case .putBack(_, let path): .trash(path)
            case .uncreated(let path, .drop, let url): .putBack(url, to: path)
            case .uncreated(let path, let origin, _): .make(path, from: origin)
            case .moved(let from, let to): .move(from: to, to: from)
            case .trashed(let path, let url), .replaced(let path, let url): .putBack(url, to: path)
            case .deleted(let path):
                preconditionFailure("an undo can't bring back \(path), which was deleted")
            }
        }
    }

    /// The paths it reads without changing, as known before it runs.
    var reads: [String] {
        switch self {
        case .copy(let sources, _), .duplicate(let sources): sources
        case .undo(let record, _, _):
            Self.steps(undoing: record).compactMap { $0.readsSource ? $0.source : nil }
        case .move, .trash, .rename, .newFolder, .deleteImmediately, .receive: []
        }
    }

    /// The paths it creates, moves or removes, as known before it runs. A duplicate's and a new
    /// folder's names are picked when they run, so they aren't here.
    var changes: [String] {
        switch self {
        case .copy(let sources, let folder):
            sources.map { Self.path(of: $0, in: folder) }
        case .move(let sources, let folder):
            sources + sources.map { Self.path(of: $0, in: folder) }
        case .trash(let paths), .deleteImmediately(let paths):
            paths
        case .rename(let path, let name):
            [path, Self.renamed(path, to: name)]
        case .newFolder, .duplicate, .receive:
            []
        case .undo(let record, _, _):
            Self.steps(undoing: record).flatMap { step in
                let changed = step.readsSource ? nil : step.source
                return [changed, step.destination].compactMap { $0 }
            }
        }
    }

    /// `path` as the refusal checks compare it: without case and with Unicode normalized, as
    /// APFS compares names by default, and without trailing slashes. On a case-sensitive volume
    /// two different items can compare equal, which only refuses more.
    public static func comparable(_ path: String) -> String {
        var path = path.folding(options: .caseInsensitive, locale: nil)
            .precomposedStringWithCanonicalMapping
        while path.utf8.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The first of `sources` that `folder` is or is inside, compared as `comparable` gives
    /// them: a copy or move of it into `folder` would go into itself. Nil when there is none.
    public static func source(holding folder: String, among sources: [String]) -> String? {
        let target = comparable(folder)
        return sources.first { isPath(target, atOrUnder: comparable($0)) }
    }

    /// Where `source` goes when it moves or is copied into `folder`.
    static func path(of source: String, in folder: String) -> String {
        join(folder, lastComponent(of: source))
    }

    /// The path `path` has once renamed to `name`.
    static func renamed(_ path: String, to name: String) -> String {
        join(parentPath(of: path), name)
    }
}
