import Base
import Foundation

/// An item in the sidebar's Favorites: the path it was last found at and, once one is made, a
/// bookmark of it, which follows the item when it is moved or renamed, as Finder's sidebar
/// follows it (docs/decisions/0107-sidebar-favorites.md). `Settings.favorites` stores the list.
public struct Favorite: Hashable, Sendable {
    /// The item's absolute path when it was last found.
    public let path: String
    /// The item's bookmark; nil until one is made, as for the default favorites and an item just
    /// dropped in.
    public let bookmark: Data?

    /// A favorite at `path`.
    ///
    /// - Precondition: `path` is absolute.
    public init(path: String, bookmark: Data? = nil) {
        precondition(path.hasPrefix("/"), "a favorite's path \(path) isn't absolute")
        self.path = path
        self.bookmark = bookmark
    }

    /// The favorites the sidebar starts with, Finder's that the app has: Applications, Desktop,
    /// Documents, Downloads and the home folder `home`.
    public static func defaults(home: String) -> [Favorite] {
        let inHome = { (name: String) in Location(path: home).child(named: name).folderPath }
        return [
            "/Applications", inHome("Desktop"), inHome("Documents"), inHome("Downloads"), home,
        ].map { Favorite(path: $0) }
    }

    /// The name the sidebar shows: the item's own, from its path.
    public var name: String { Location(path: path).name }

    /// Whether `paths` holds no path twice, compared as the file system compares names
    /// (`FileOperation.comparable`).
    public static func areDistinct(_ paths: [String]) -> Bool {
        Set(paths.map(FileOperation.comparable)).count == paths.count
    }

    // MARK: Stored shape

    private static let pathKey = "path"
    private static let bookmarkKey = "bookmark"

    /// The favorite as `Settings` stores it: a dictionary of its path and, once made, its
    /// bookmark.
    var stored: [String: Any] {
        var stored: [String: Any] = [Self.pathKey: path]
        if let bookmark { stored[Self.bookmarkKey] = bookmark }
        return stored
    }

    /// The favorite `stored` holds; nil unless it is a dictionary with an absolute path string
    /// under "path", data or nothing under "bookmark", and no other key.
    init?(stored: Any) {
        guard let dictionary = stored as? [String: Any],
            Set(dictionary.keys).isSubset(of: [Self.pathKey, Self.bookmarkKey]),
            let path = dictionary[Self.pathKey] as? String, path.hasPrefix("/")
        else { return nil }
        let bookmark = dictionary[Self.bookmarkKey]
        guard bookmark == nil || bookmark is Data else { return nil }
        self.init(path: path, bookmark: bookmark as? Data)
    }

    // MARK: Resolving

    /// What a favorite is on the disk.
    public enum State: Equatable, Sendable {
        /// Not looked at yet.
        case unknown
        /// A folder, which opens in a pane.
        case folder
        /// A file or a package, which opens in its app (0093-packages-are-files.md).
        case file
        /// Not found: its bookmark doesn't resolve, nothing is at its path, or it is in a Trash.
        case missing
    }

    /// A favorite as found on the disk: where it is now, with a bookmark made if it had none or
    /// its own was stale, and what it is.
    public struct Resolution: Equatable, Sendable {
        public let favorite: Favorite
        public let state: State

        public init(favorite: Favorite, state: State) {
            self.favorite = favorite
            self.state = state
        }
    }

    /// Finds the item on the disk: through its bookmark when it has one, else, or when the
    /// bookmark doesn't resolve or leads into a Trash, at its path, with a new bookmark made
    /// there, so a folder deleted and made again at the same path is found. An item that moved
    /// has its new path; one at a path the old one only names another way, as `/tmp` names
    /// `/private/tmp`, keeps its path. A symbolic link is what it points to, as Finder opens a
    /// link to a folder as the folder. A missing item is returned as it was, bookmark included,
    /// so one put back from the Trash is found again. Volumes aren't mounted to look, and no UI
    /// is shown.
    ///
    /// It reads the disk, which a share that has stopped answering can block, so it runs on a
    /// `BlockingCallThread` (docs/decisions/0038-slow-volumes.md).
    public nonisolated static func resolve(_ favorite: Favorite) -> Resolution {
        BlockingCallThread.requireCurrent()
        if let bookmark = favorite.bookmark,
            let resolution = resolve(favorite, through: bookmark)
        {
            return resolution
        }
        let url = URL(fileURLWithPath: favorite.path, isDirectory: false)
        guard !isInTrash(favorite.path), let state = state(at: url) else {
            return Resolution(favorite: favorite, state: .missing)
        }
        return Resolution(
            favorite: Favorite(path: favorite.path, bookmark: bookmark(of: url)), state: state)
    }

    /// `favorite` found through `bookmark`; nil when the bookmark doesn't resolve, or leads into
    /// a Trash or to nothing.
    private nonisolated static func resolve(_ favorite: Favorite, through bookmark: Data)
        -> Resolution?
    {
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                relativeTo: nil, bookmarkDataIsStale: &isStale)
        } catch {
            // The bookmark's item is gone, on a volume that isn't mounted, or the data isn't a
            // bookmark: the caller looks at the path instead, and an item not there is missing,
            // which the row shows.
            return nil
        }
        guard !isInTrash(url.path), let state = state(at: url) else { return nil }
        var path = url.path
        if path != favorite.path, let real = realPath(path), real == realPath(favorite.path) {
            path = favorite.path
        }
        return Resolution(
            favorite: Favorite(path: path, bookmark: isStale ? self.bookmark(of: url) : bookmark),
            state: state)
    }

    /// What is at `url`, following links: a folder, or a file or package; nil for nothing, a
    /// broken link or a loop of links, which realpath can't resolve.
    private nonisolated static func state(at url: URL) -> State? {
        guard let real = realPath(url.path) else { return nil }
        let target = URL(fileURLWithPath: real, isDirectory: false)
        let values: URLResourceValues
        do {
            values = try target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        } catch {
            // realpath found the item a moment ago, so it went away or became unreadable since:
            // either way it can't be opened, which is what missing means, and the row shows it.
            return nil
        }
        return values.isDirectory == true && values.isPackage != true ? .folder : .file
    }

    /// A bookmark of `url`; nil when the system can't make one, as for an item that went away
    /// since it was found. The item then keeps its path alone, which still opens it, and the
    /// next resolve tries again, so the failure costs only following a move until then and
    /// isn't reported.
    private nonisolated static func bookmark(of url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Whether `path` is in a Trash: the user's, or a volume's.
    nonisolated static func isInTrash(_ path: String) -> Bool {
        pathComponents(path).contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    /// `path` with every link resolved, or nil when it can't be.
    private nonisolated static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
