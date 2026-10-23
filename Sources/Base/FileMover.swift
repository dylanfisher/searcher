import Darwin
import Foundation

/// Moves or renames an item within one volume, never replacing what is already at the
/// destination.
public enum FileMover {
    /// Moves `source` to `destination` with `renamex_np` and `RENAME_EXCL`, so an existing item
    /// at `destination` fails the move with `exists` instead of being replaced; the check and the
    /// move are one call, so nothing created in between is lost. A destination on another volume
    /// fails with `crossVolume`, and the caller copies instead. A rename that changes only case
    /// works on a case-insensitive volume. Errors carry `destination` for `exists` and `source`
    /// otherwise. Blocks the calling thread; call it off the main thread.
    public static func move(_ source: String, to destination: String) throws(FileOperationError) {
        precondition(
            !Thread.isMainThread, "FileMover does file-system I/O; call it off the main thread")
        guard renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            throw FileOperationError(errno: code, path: code == EEXIST ? destination : source)
        }
    }

    /// Exchanges the items at `first` and `second`, which are on one volume: afterwards each path
    /// names the other's item. Where the volume can, this is one `renamex_np` with `RENAME_SWAP`,
    /// so neither path is ever empty; APFS can. HFS+ and exFAT refuse it with `ENOTSUP`, and there
    /// it is three renames through a temporary name beside `first`, so `second` is missing for a
    /// moment. A rename that fails puts back what the ones before it moved, and its error is
    /// thrown; if a put-back fails, that error is thrown instead, since it says what is where.
    /// Blocks the calling thread; call it off the main thread.
    public static func swap(_ first: String, with second: String) throws(FileOperationError) {
        precondition(
            !Thread.isMainThread, "FileMover does file-system I/O; call it off the main thread")
        if renamex_np(first, second, UInt32(RENAME_SWAP)) == 0 { return }
        let code = errno
        guard code == ENOTSUP else {
            let missing = code == ENOENT && access(first, F_OK) != 0
            throw FileOperationError(errno: code, path: missing ? first : second)
        }
        let aside =
            (first as NSString).deletingLastPathComponent + "/.searcher-swap-"
            + UUID().uuidString
        // Plain renames: exFAT refuses `RENAME_EXCL` too, and each target is a new name or one
        // the rename before emptied.
        try rename(first, to: aside)
        do {
            try rename(second, to: first)
        } catch {
            try rename(aside, to: first)
            throw error
        }
        do {
            try rename(aside, to: second)
        } catch {
            try rename(first, to: second)
            try rename(aside, to: first)
            throw error
        }
    }

    /// `rename(2)`, which replaces an item at `destination`. Errors carry `source`.
    private static func rename(_ source: String, to destination: String)
        throws(FileOperationError)
    {
        guard Darwin.rename(source, destination) == 0 else {
            throw FileOperationError(errno: errno, path: source)
        }
    }
}
