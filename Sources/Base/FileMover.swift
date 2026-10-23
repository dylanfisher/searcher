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
}
