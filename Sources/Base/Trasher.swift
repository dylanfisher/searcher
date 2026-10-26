import Darwin
import Foundation

/// Moves items to the Trash of their volume, one at a time, and reports where each one went so
/// Undo can move it back. An item whose ACL denies deleting it is moved as Finder moves it. See
/// docs/decisions/0059-trash.md and 0105-trash-past-a-deny-delete-acl.md.
public struct Trasher: Sendable {
    /// Moves the item at a URL to the Trash and returns its URL there.
    public typealias TrashCall = @Sendable (URL) throws -> URL

    private let trashCall: TrashCall

    /// `trashCall` is `FileManager.trashItem` unless a test injects a failure.
    public init(trashCall: @escaping TrashCall = Trasher.trashItem) {
        self.trashCall = trashCall
    }

    /// Moves the item at `path` to its volume's Trash and returns its URL there. A volume without
    /// a trash throws `noTrash` and leaves the item where it is; deleting it instead is the
    /// caller's question to ask, and `deletePermanently` its answer. An item whose ACL denies
    /// deleting it still goes, and carries that ACL in the Trash (`pastDenyDelete`). Blocks the
    /// calling thread; call it off the main thread.
    public func trash(_ path: String) throws(FileOperationError) -> URL {
        precondition(
            !Thread.isMainThread, "Trasher does file-system I/O; call it off the main thread")
        return try Self.pastDenyDelete(path) { () throws(FileOperationError) in
            do {
                return try trashCall(URL(fileURLWithPath: path))
            } catch {
                throw Self.operationError(error, path: path)
            }
        }
    }

    /// Moves the item at `url`, in a Trash, back to `path` with `FileMover.move`, past an ACL
    /// that denies deleting it, as `trash` moved it in. Blocks the calling thread; call it off
    /// the main thread.
    public static func putBack(_ url: URL, to path: String) throws(FileOperationError) {
        precondition(
            !Thread.isMainThread, "Trasher does file-system I/O; call it off the main thread")
        _ = try pastDenyDelete(url.path) { () throws(FileOperationError) in
            try FileMover.move(url.path, to: path)
            return URL(fileURLWithPath: path)
        }
    }

    /// Runs `move`, which moves the item at `path` and returns where it went. A move refused for
    /// permission, of an item whose ACL has entries that deny deleting it, takes those entries
    /// off, moves the item again, and puts the whole ACL back on the item where it went, as
    /// Finder does. Only the item's owner can take them off, and nobody can on a locked item;
    /// then the refusal is thrown and the item is left as it was. If the second move fails too,
    /// the ACL goes back on the item where it is and the first refusal is thrown. An ACL that
    /// can't be put back throws that error, with the path of the item that lacks it.
    static func pastDenyDelete(
        _ path: String, _ move: () throws(FileOperationError) -> URL
    ) throws(FileOperationError) -> URL {
        let refusal: FileOperationError
        do {
            return try move()
        } catch let error where error.reason == .permissionDenied {
            refusal = error
        }
        // The `_link_` calls don't follow a symlink, which `trashItem` and `rename` move as itself.
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { throw refusal }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let lifted = withoutDenyDelete(acl) else { throw refusal }
        defer { acl_free(UnsafeMutableRawPointer(lifted)) }
        guard acl_set_link_np(path, ACL_TYPE_EXTENDED, lifted) == 0 else { throw refusal }
        let moved: URL
        do {
            moved = try move()
        } catch {
            try setACL(acl, on: path)
            throw refusal
        }
        try setACL(acl, on: moved.path)
        return moved
    }

    /// A copy of `acl` without its entries that deny deleting the item, or nil if it has none.
    private static func withoutDenyDelete(_ acl: acl_t) -> acl_t? {
        var kept: acl_t? = acl_init(0)
        guard kept != nil else {
            preconditionFailure("acl_init failed: errno \(errno)")
        }
        var dropsAny = false
        var entry: acl_entry_t?
        var id = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, id, &entry) == 0, let current = entry {
            id = ACL_NEXT_ENTRY.rawValue
            var tag = ACL_UNDEFINED_TAG
            var permissions: acl_permset_t?
            if acl_get_tag_type(current, &tag) == 0, tag == ACL_EXTENDED_DENY,
                acl_get_permset(current, &permissions) == 0,
                acl_get_perm_np(permissions, ACL_DELETE) == 1
            {
                dropsAny = true
                continue
            }
            var copy: acl_entry_t?
            guard acl_create_entry(&kept, &copy) == 0, acl_copy_entry(copy, current) == 0 else {
                preconditionFailure("copying an ACL entry failed: errno \(errno)")
            }
        }
        guard dropsAny else {
            acl_free(UnsafeMutableRawPointer(kept))
            return nil
        }
        return kept
    }

    /// Sets `acl` on the item at `path`, not following a symlink.
    private static func setACL(_ acl: acl_t, on path: String) throws(FileOperationError) {
        guard acl_set_link_np(path, ACL_TYPE_EXTENDED, acl) == 0 else {
            throw FileOperationError(errno: errno, path: path)
        }
    }

    /// Deletes the item at `path`, and everything in it if it is a folder, without the Trash.
    /// Call it only after the user has answered a delete-immediately question for this item, or
    /// on the source of a move to another volume once its copy is complete. Blocks the calling
    /// thread; call it off the main thread.
    public static func deletePermanently(_ path: String) throws(FileOperationError) {
        precondition(
            !Thread.isMainThread, "Trasher does file-system I/O; call it off the main thread")
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw operationError(error, path: path)
        }
    }

    /// `FileManager.trashItem`. It returned a result URL for every item in spike S7's runs, so a
    /// missing one is an error rather than a success with nowhere to undo from.
    public static let trashItem: TrashCall = { url in
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else {
            throw FileOperationError(reason: .other, path: url.path, errno: nil)
        }
        return result as URL
    }

    /// The `FileOperationError` for an error `FileManager` threw on `path`. Its errors carry a
    /// POSIX error when a system call failed; `trashItem`'s carry an OSStatus instead, so those
    /// are read from the Cocoa code.
    private static func operationError(_ error: any Error, path: String) -> FileOperationError {
        if let error = error as? FileOperationError { return error }
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain {
            return FileOperationError(errno: Int32(error.code), path: path)
        }
        guard error.domain == NSCocoaErrorDomain else {
            return FileOperationError(reason: .other, path: path, errno: nil)
        }
        // Where the volume has no trash. Not yet seen from a real volume: see 0059's SMB and
        // exFAT runs.
        if error.code == CocoaError.featureUnsupported.rawValue {
            return FileOperationError(reason: .noTrash, path: path, errno: nil)
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
            underlying.domain == NSPOSIXErrorDomain
        {
            return FileOperationError(errno: Int32(underlying.code), path: path)
        }
        let reason: FileOperationError.Reason =
            switch CocoaError.Code(rawValue: error.code) {
            case .fileNoSuchFile, .fileReadNoSuchFile: .sourceGone
            case .fileReadNoPermission, .fileWriteNoPermission, .fileWriteVolumeReadOnly:
                .permissionDenied
            case .fileWriteOutOfSpace: .noSpace
            default: .other
            }
        return FileOperationError(reason: reason, path: path, errno: nil)
    }
}
