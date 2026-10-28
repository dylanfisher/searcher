import Darwin
import Foundation

/// Reads and writes an item's Finder tags by name, through `NSURL`'s `tagNamesKey`, the
/// supported way to change them. The system keeps each name's color: "Red" is stored as Finder
/// stores it, `Red\n6` in the item's `_kMDItemUserTags`, and shows red in Finder. An item that is
/// a symlink has the tags of the item it points to, which both calls follow
/// (docs/decisions/0121-tag-commands.md).
public enum FinderTags {
    /// The tags of the item at `path`, in the order Finder lists them, read from the disk each
    /// time rather than from a cached `URL`. Blocks the calling thread; call it off the main
    /// thread.
    public static func names(at path: String) throws(FileOperationError) -> [String] {
        preconditionOffMain("FinderTags")
        var names: AnyObject?
        do {
            try NSURL(fileURLWithPath: path).getResourceValue(&names, forKey: .tagNamesKey)
        } catch {
            throw operationError(error, path: path)
        }
        // An item without tags reads as nil.
        return names as? [String] ?? []
    }

    /// Gives the item at `path` the tags `names`, in that order, in place of the ones it has.
    /// Blocks the calling thread; call it off the main thread.
    public static func set(_ names: [String], at path: String) throws(FileOperationError) {
        preconditionOffMain("FinderTags")
        do {
            try NSURL(fileURLWithPath: path).setResourceValue(names, forKey: .tagNamesKey)
        } catch {
            throw operationError(error, path: path)
        }
    }

    /// The `FileOperationError` for an error `NSURL` threw on `path`. A refused write and a
    /// missing item come as Carbon `OSStatus` codes, not errnos: `afpAccessDenied` (-5000) for a
    /// read-only or locked file, `fnfErr` (-43) for an item that is gone.
    private static func operationError(_ error: any Error, path: String) -> FileOperationError {
        let error = error as NSError
        let posix =
            error.domain == NSPOSIXErrorDomain
            ? error : error.userInfo[NSUnderlyingErrorKey] as? NSError
        if let posix, posix.domain == NSPOSIXErrorDomain {
            return FileOperationError(errno: Int32(posix.code), path: path)
        }
        let reason: FileOperationError.Reason =
            switch (error.domain, error.code) {
            case (NSOSStatusErrorDomain, -5000): .permissionDenied
            case (NSOSStatusErrorDomain, -43): .sourceGone
            case (NSCocoaErrorDomain, CocoaError.fileNoSuchFile.rawValue),
                (NSCocoaErrorDomain, CocoaError.fileReadNoSuchFile.rawValue):
                .sourceGone
            case (NSCocoaErrorDomain, CocoaError.fileReadNoPermission.rawValue),
                (NSCocoaErrorDomain, CocoaError.fileWriteNoPermission.rawValue),
                (NSCocoaErrorDomain, CocoaError.fileWriteVolumeReadOnly.rawValue):
                .permissionDenied
            default: .other
            }
        return FileOperationError(reason: reason, path: path, errno: nil)
    }
}
