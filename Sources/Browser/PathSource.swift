import Base
import Foundation

/// For a query that starts with `/` or `~` and holds a `/`, the folders in the typed parent: the
/// text up to the last `/`, expanded by `PathInput`. They are listed through `ListingService`,
/// off the main actor, and matched by the name typed after that `/`. Each title is the typed
/// parent followed by the folder's name, and choosing one shows it in the focused pane, its first
/// row selected once listed. A folder whose name starts with a dot is listed only once the typed
/// name does too; one hidden by its flag, such as `~/Library`, is always listed, as Finder's Go
/// to Folder completes it. A streaming source: the parent is listed once while the typed name
/// changes, and the folders found so far are handed over on every key.
@MainActor
public final class PathSource: PaletteSource {
    private let service: ListingService
    private let history: @MainActor () -> FolderHistory
    private let focusedPane: @MainActor @Sendable () -> Pane
    private let home: String
    private let now: @Sendable () -> Date
    /// The parent being listed, as typed, with its load and the items found so far.
    private var parent: Parent?
    /// Hands over the items for the latest query.
    private var deliver: (@MainActor ([PaletteItem]) -> Void)?
    /// Whether the latest query's typed name starts with a dot.
    private var showsDotFolders = false

    private final class Parent {
        let typed: String
        let load: ListingLoad
        var items = Items()

        init(typed: String, load: ListingLoad) {
            self.typed = typed
            self.load = load
        }
    }

    /// One listing's folders as items.
    struct Items: Sendable {
        /// The folders whose names don't start with a dot.
        var shown: [PaletteItem] = []
        /// Every folder.
        var all: [PaletteItem] = []
    }

    /// Makes one load's items on its thread, keeping each folder's item for the updates after,
    /// so a full listing after a first batch or cached rows prepares only the folders new to it.
    final class ItemMaker: @unchecked Sendable {
        private let location: Location
        private let typed: String
        private let history: FolderHistory
        private let now: Date
        private let focusedPane: @MainActor @Sendable () -> Pane
        // `lock` guards `made` and `storedMadeCount`.
        private let lock = NSLock()
        private var made: [String: PaletteItem] = [:]
        private var storedMadeCount = 0

        init(
            location: Location, typed: String, history: FolderHistory, now: Date,
            focusedPane: @escaping @MainActor @Sendable () -> Pane
        ) {
            self.location = location
            self.typed = typed
            self.history = history
            self.now = now
            self.focusedPane = focusedPane
        }

        /// How many items were prepared so far.
        var madeCount: Int { lock.withLock { storedMadeCount } }

        /// The folders `update` lists, as items; none for a load that failed, and nil for one
        /// that is only slow, which keeps the folders found before.
        func items(for update: ListingUpdate) -> Items? {
            let listing: Listing
            switch update {
            case .cached(let cached, _, _): listing = cached
            case .firstBatch(let batch, _): listing = batch
            case .full(let full, _): listing = full
            case .failed, .volumeGone, .notConnected: return Items()
            case .slow, .gaveUp: return nil
            }
            return lock.withLock {
                var items = Items()
                for entry in listing.entries where entry.type == .directory {
                    let item = made[entry.name] ?? makeItem(named: entry.name)
                    items.all.append(item)
                    if !entry.name.hasPrefix(".") { items.shown.append(item) }
                }
                return items
            }
        }

        private func makeItem(named name: String) -> PaletteItem {
            let folder = location.child(named: name)
            let focusedPane = focusedPane
            let item = PaletteItem(
                id: .folder(path: folder.folderPath), title: typed + name,
                frecency: history.frecency(of: folder.folderPath, at: now),
                matchOffset: typed.utf8.count
            ) { focusedPane().navigateSelectingFirstRow(to: folder) }
            made[name] = item
            storedMadeCount += 1
            return item
        }
    }

    /// `focusedPane` is the pane a chosen folder is shown in.
    public init(
        service: ListingService, history: @escaping @MainActor () -> FolderHistory,
        focusedPane: @escaping @MainActor @Sendable () -> Pane, home: String,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.service = service
        self.history = history
        self.focusedPane = focusedPane
        self.home = home
        self.now = now
    }

    public func gather(_ query: String, deliver: @escaping @MainActor ([PaletteItem]) -> Void) {
        guard query.hasPrefix("/") || query.hasPrefix("~"),
            let slash = query.lastIndex(of: "/")
        else {
            cancel()
            return deliver([])
        }
        let typed = String(query[...slash])
        let name = query[query.index(after: slash)...]
        if parent?.typed != typed {
            cancel()
            parent = list(typed)
        }
        self.deliver = deliver
        showsDotFolders = name.hasPrefix(".")
        handOver()
    }

    private func handOver() {
        guard let parent, let deliver else { return }
        deliver(showsDotFolders ? parent.items.all : parent.items.shown)
    }

    public func cancel() {
        parent?.load.cancel()
        parent = nil
        deliver = nil
    }

    /// Starts listing the folder `typed` names.
    private func list(_ typed: String) -> Parent {
        guard let location = PathInput.location(for: typed, in: Location(path: "/"), home: home)
        else {
            preconditionFailure("\"\(typed)\" holds a / but names no folder")
        }
        let maker = ItemMaker(
            location: location, typed: typed, history: history(), now: now(),
            focusedPane: focusedPane)
        let load = service.load(
            location, priority: .focused, prepare: { maker.items(for: $0) },
            onUpdate: { [weak self] items in
                // A cancelled load hands over nothing more, so this is the parent's load.
                guard let self, let items, let parent = self.parent else { return }
                precondition(parent.typed == typed, "the load of \(typed) outlived its parent")
                parent.items = items
                handOver()
            })
        return Parent(typed: typed, load: load)
    }
}
