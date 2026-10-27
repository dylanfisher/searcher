import Darwin
import Foundation

/// Creates folders, by a given name or by Finder's "untitled folder" names.
public enum FolderMaker {
    /// Creates the folder `name` in `folder` and returns its path. A name `FileNameRule` rejects
    /// throws `invalidName`, and a name already taken throws `exists`. Blocks the calling thread;
    /// call it off the main thread.
    public static func makeFolder(named name: String, in folder: String) throws(FileOperationError)
        -> String
    {
        precondition(
            !Thread.isMainThread, "FolderMaker does file-system I/O; call it off the main thread")
        let path = join(folder, name)
        if FileNameRule.problem(with: name) != nil {
            throw FileOperationError(reason: .invalidName, path: path, errno: nil)
        }
        // 0777 less the umask, as Finder and `mkdir` create folders.
        guard mkdir(path, 0o777) == 0 else { throw FileOperationError(errno: errno, path: path) }
        return path
    }

    /// Creates "untitled folder", or the first free "untitled folder N", in `folder` and returns
    /// its path. Blocks the calling thread; call it off the main thread.
    public static func makeUntitledFolder(in folder: String) throws(FileOperationError) -> String {
        while true {
            let name = try UniqueName.newFolder { name throws(FileOperationError) in
                try UniqueName.isTaken(name, in: folder)
            }
            do {
                return try makeFolder(named: name, in: folder)
            } catch let error where error.reason == .exists {
                // Something took the name between the check and `mkdir`; pick the next one.
                continue
            }
        }
    }
}
