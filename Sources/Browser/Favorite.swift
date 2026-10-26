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
        let inHome = { (name: String) in Location(path: home).child(named: name).path }
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

    /// Finds the item on the disk: through its bookmark when it has one, else at its path. An
    /// item that moved has its new path; one at a path the old one only names another way, as
    /// `/tmp` names `/private/tmp`, keeps its path. A missing item is returned as it was.
    /// Volumes aren't mounted to look, and no UI is shown.
    ///
    /// It reads the disk, which a share that has stopped answering can block, so it runs on a
    /// `BlockingCallThread` (docs/decisions/0038-slow-volumes.md).
    public nonisolated static func resolve(_ favorite: Favorite) -> Resolution {
        BlockingCallThread.requireCurrent()
        let missing = Resolution(favorite: favorite, state: .missing)
        var url = URL(fileURLWithPath: favorite.path, isDirectory: false)
        var bookmark = favorite.bookmark
        if let data = favorite.bookmark {
            var isStale = false
            do {
                url = try URL(
                    resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                    relativeTo: nil, bookmarkDataIsStale: &isStale)
            } catch {
                return missing
            }
            if isStale { bookmark = nil }
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        } catch {
            return missing
        }
        guard !isInTrash(url.path) else { return missing }
        var path = url.path
        if path != favorite.path, let real = realPath(path), real == realPath(favorite.path) {
            path = favorite.path
        }
        if bookmark == nil {
            // An item the system can't bookmark keeps its path alone; the next resolve tries
            // again.
            bookmark = try? url.bookmarkData(
                options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        let isFolder = values.isDirectory == true && values.isPackage != true
        return Resolution(
            favorite: Favorite(path: path, bookmark: bookmark), state: isFolder ? .folder : .file)
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
