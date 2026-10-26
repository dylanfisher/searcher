import Base
import Foundation

/// The files of Finder's sidebar glyphs, which ship in the system's CoreTypes bundle as
/// `Sidebar*.icns` (docs/decisions/0107-sidebar-favorites.md,
/// docs/decisions/0108-sidebar-locations.md).
public enum CoreTypesIcons {
    static let directory = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources"

    /// The bytes of each icon file named in `names`, such as `SidebarHomeFolder`, read on a
    /// `BlockingCallThread`. A name the bundle has no file for, or whose file can't be read, is
    /// left out of the result, so the caller shows its own stand-in for it.
    public static func read(_ names: [String]) async -> [String: Data] {
        let directory = directory
        return await BlockingCallThread.run { () -> [String: Data] in
            var files: [String: Data] = [:]
            for name in names {
                let url = URL(fileURLWithPath: "\(directory)/\(name).icns", isDirectory: false)
                if let data = try? Data(contentsOf: url) {
                    files[name] = data
                }
            }
            return files
        }
    }
}
