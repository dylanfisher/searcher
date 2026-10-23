import AppKit
import Browser

/// What a drop of files does, by Finder's rules: items on the target folder's volume move and
/// items from another volume copy; Option copies and Command moves either way, and Option onto
/// the items' own folder duplicates them with Finder's copy names. AppKit narrows
/// the drag's allowed operations by the keys held, Option to copy, Command to generic and
/// Command-Option to link, so the keys are read from that mask. Finder makes an alias for a
/// link; Searcher makes none, so a link-only drag drops nothing. Volumes come from the
/// `MountTable`, so deciding reads nothing from the disk (docs/decisions/0071-drag-and-drop.md).
enum DropOperation: Equatable {
    case copy
    case move
    case duplicate

    /// The operation for dropping `sources` into `folder` while the drag allows `allowed`, or
    /// nil for none: when a source is `folder` or holds it, which the queue would refuse, or
    /// when every source is in `folder` already and the drag allows more than a copy, as with
    /// no keys held; with only a copy allowed, as with Option, they duplicate. A drop moves only
    /// when every source is on the folder's volume; one on no volume the table knows counts as
    /// another volume.
    @MainActor
    init?(
        dropping sources: [String], into folder: String, allowed: NSDragOperation,
        mounts: MountTable
    ) {
        guard !sources.isEmpty, FileOperation.source(holding: folder, among: sources) == nil
        else { return nil }
        let target = FileOperation.comparable(folder)
        if sources.allSatisfy({
            FileOperation.comparable(($0 as NSString).deletingLastPathComponent) == target
        }) {
            guard allowed == .copy else { return nil }
            self = .duplicate
            return
        }
        let canCopy = allowed.contains(.copy)
        let canMove = !allowed.isDisjoint(with: [.move, .generic])
        if allowed == .copy {
            self = .copy
        } else if !canCopy, canMove {
            self = .move
        } else if canCopy, canMove {
            let volume = mounts.volume(of: folder)
            let isSameVolume =
                volume != nil && sources.allSatisfy { mounts.volume(of: $0) == volume }
            self = isSameVolume ? .move : .copy
        } else if canCopy {
            self = .copy
        } else {
            return nil
        }
    }

    /// What the drag shows for this operation, one of those `allowed` has: a move shows as
    /// generic when Command left only that.
    func dragOperation(allowed: NSDragOperation) -> NSDragOperation {
        switch self {
        case .copy, .duplicate: .copy
        case .move: allowed.contains(.move) ? .move : .generic
        }
    }

    /// The queued operation that puts `sources` in `folder`; a duplicate's are in it already.
    func fileOperation(_ sources: [String], into folder: String) -> FileOperation {
        switch self {
        case .copy: .copy(sources, into: folder)
        case .move: .move(sources, into: folder)
        case .duplicate: .duplicate(sources)
        }
    }
}
