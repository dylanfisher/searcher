import Base
import Foundation

/// The sidebar's Favorites, app-wide: the list `Settings.favorites` stores, with what each item
/// was last found to be on the disk. Every window's sidebar shows the same list, and a change
/// made in one shows in all (docs/decisions/0107-sidebar-favorites.md).
///
/// Items are looked for off the main thread, through their bookmarks, by `refresh` and before
/// each open, so an item moved or renamed outside the app is followed, as Finder's sidebar
/// follows it. An item that isn't found stays in the list, greyed, and comes back when it is
/// found again, as an ejected disk's or a share's does when it mounts again.
@MainActor
public final class Favorites {
    /// A row of the list.
    public struct Item: Equatable, Sendable {
        public let path: String
        public let state: Favorite.State

        /// The name the row shows.
        public var name: String { Location(path: path).name }
    }

    private let settings: Settings
    private let resolve: @Sendable (Favorite) -> Favorite.Resolution
    /// What each favorite was last found to be, by path; a path not in it is `.unknown`.
    private var states: [String: Favorite.State] = [:]
    /// The paths `refresh` is looking for now, so a second refresh doesn't look again meanwhile.
    private(set) var resolving: Set<String> = []
    /// Counts the opens, so only the latest one acts once its item is found.
    private var openRequest = 0
    private var observers: [Observer] = []

    private struct Observer {
        weak var owner: AnyObject?
        let handler: @MainActor () -> Void
    }

    /// The favorites in `settings`. `resolve` finds an item on the disk; it is called on a
    /// `BlockingCallThread`.
    public init(
        settings: Settings,
        resolve: @escaping @Sendable (Favorite) -> Favorite.Resolution = Favorite.resolve
    ) {
        self.settings = settings
        self.resolve = resolve
    }

    /// The list, top to bottom.
    public var items: [Item] {
        settings.favorites.map { Item(path: $0.path, state: states[$0.path] ?? .unknown) }
    }

    /// Whether `path` is in the list, compared as the file system compares names.
    public func contains(_ path: String) -> Bool {
        let comparable = FileOperation.comparable(path)
        return settings.favorites.contains { FileOperation.comparable($0.path) == comparable }
    }

    /// Runs `handler` after each change of what an item was found to be, for as long as `owner`
    /// exists. Changes of the list itself are changes of `Settings`, which its own observers hear.
    public func observe(for owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        observers.append(Observer(owner: owner, handler: handler))
    }

    // MARK: Changing the list

    /// Adds the items at `paths` before the item at `index`, or at the end for an index past
    /// it, in their order, leaving out each one the list already has, and looks for them.
    public func insert(_ paths: [String], at index: Int) {
        var list = settings.favorites
        var added: [Favorite] = []
        for path in paths where !contains(path) && Favorite.areDistinct(added.map(\.path) + [path])
        {
            added.append(Favorite(path: path))
        }
        guard !added.isEmpty else { return }
        list.insert(contentsOf: added, at: min(max(index, 0), list.count))
        settings.favorites = list
        for favorite in added {
            look(for: favorite)
        }
    }

    /// Moves the item at `path` to before the item at `index`, as the list was before the move,
    /// or to the end for an index past it.
    public func move(_ path: String, to index: Int) {
        var list = settings.favorites
        guard let from = list.firstIndex(where: { $0.path == path }) else { return }
        let favorite = list.remove(at: from)
        let to = min(max(index > from ? index - 1 : index, 0), list.count)
        list.insert(favorite, at: to)
        settings.favorites = list
    }

    /// Takes the item at `path` out of the list.
    public func remove(_ path: String) {
        settings.favorites.removeAll { $0.path == path }
        states[path] = nil
    }

    // MARK: Finding the items

    /// Looks for every item on the disk again, off the main thread, but those still being looked
    /// for. The app calls it as it becomes active, since an item may have moved meanwhile.
    public func refresh() {
        for favorite in settings.favorites {
            look(for: favorite)
        }
    }

    private func look(for favorite: Favorite) {
        guard resolving.insert(favorite.path).inserted else { return }
        let resolve = resolve
        Task { [weak self] in
            let resolution = await BlockingCallThread.run { resolve(favorite) }
            guard let self else { return }
            resolving.remove(favorite.path)
            apply(resolution, to: favorite)
            // A favorite removed and added again at this path while it was looked for is a new
            // one, which the find didn't apply to and `insert` couldn't look for meanwhile.
            if let added = settings.favorites.first(where: { $0.path == favorite.path }),
                states[added.path] == nil
            {
                look(for: added)
            }
        }
    }

    /// Shows what `favorite` was found to be, and keeps its new path and bookmark. Nothing
    /// changes when the item left the list or changed meanwhile. An item found at a path another
    /// item in the list has leaves the list, so no path is in it twice.
    private func apply(_ resolution: Favorite.Resolution, to favorite: Favorite) {
        var list = settings.favorites
        guard let index = list.firstIndex(of: favorite) else { return }
        let found = resolution.favorite
        if found.path != favorite.path {
            let comparable = FileOperation.comparable(found.path)
            // The item itself compares equal after a rename that changes only case.
            if list.indices.contains(where: {
                $0 != index && FileOperation.comparable(list[$0].path) == comparable
            }) {
                list.remove(at: index)
                states[favorite.path] = nil
                settings.favorites = list
                return
            }
            states[favorite.path] = nil
        }
        list[index] = found
        let stateChanged = states[found.path] != resolution.state
        states[found.path] = resolution.state
        settings.favorites = list
        if stateChanged { notify() }
    }

    private func notify() {
        observers.removeAll { $0.owner == nil }
        for observer in observers {
            observer.handler()
        }
    }

    // MARK: Opening

    /// Opens the item at `path` once it is found, off the main thread: a folder in the pane
    /// `pane` returns then, a file or package in its app, as a double-click on it does. An item
    /// not found opens nothing, and nor does one when `pane` returns nil or another open came
    /// after it.
    public func open(_ path: String, in pane: @escaping @MainActor () -> Pane?) {
        guard let favorite = settings.favorites.first(where: { $0.path == path }) else { return }
        openRequest += 1
        let request = openRequest
        let resolve = resolve
        Task { [weak self] in
            let resolution = await BlockingCallThread.run { resolve(favorite) }
            guard let self else { return }
            apply(resolution, to: favorite)
            guard request == openRequest, let pane = pane() else { return }
            let path = resolution.favorite.path
            switch resolution.state {
            case .folder:
                pane.navigate(to: Location(path: path))
            case .file:
                pane.systemActions.openFile(URL(fileURLWithPath: path, isDirectory: false))
            case .missing, .unknown:
                break
            }
        }
    }
}
