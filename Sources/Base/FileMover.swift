import Darwin
import Foundation

/// Moves or renames an item within one volume, never replacing what is already at the
/// destination.
public enum FileMover {
    /// Moves `source` to `destination` with `renamex_np` and `RENAME_EXCL`, so an existing item
    /// at `destination` fails the move with `exists` instead of being replaced; the check and the
    /// move are one call, so nothing created in between is lost. A destination on another volume
    /// fails with `crossVolume`, and the caller copies instead. A rename that changes only case
    /// works on a case-insensitive volume. exFAT answers `RENAME_EXCL` with `EEXIST` when another
    /// item is at the destination, and with `ENOTSUP` when it is free or names the source, as in
    /// a case-only rename; then the move checks the destination with `lstat` and calls
    /// `rename(2)`, so an item created between the check and the rename is replaced. Errors
    /// carry `destination` for `exists` and `source`
    /// otherwise. Blocks the calling thread; call it off the main thread.
    public static func move(_ source: String, to destination: String) throws(FileOperationError) {
        precondition(
            !Thread.isMainThread, "FileMover does file-system I/O; call it off the main thread")
        if renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 { return }
        var code = errno
        if code == ENOTSUP {
            if isOtherItem(at: destination, than: source) {
                throw FileOperationError(reason: .exists, path: destination, errno: EEXIST)
            }
            if rename(source, destination) == 0 { return }
            code = errno
        }
        throw FileOperationError(errno: code, path: code == EEXIST ? destination : source)
    }

    /// Whether `destination` names an item, and not the one at `source`, as it does in a
    /// case-only rename on a case-insensitive volume.
    static func isOtherItem(at destination: String, than source: String) -> Bool {
        var target = stat()
        guard lstat(destination, &target) == 0 else { return false }
        var item = stat()
        guard lstat(source, &item) == 0 else { return true }
        return target.st_dev != item.st_dev || target.st_ino != item.st_ino
    }
}
