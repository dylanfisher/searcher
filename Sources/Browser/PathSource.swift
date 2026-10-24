import Base
import Foundation

/// For a query that starts with `/` or `~` and holds a `/`, the folders in the typed parent: the
/// text up to the last `/`, expanded by `PathInput`. They are listed through `ListingService`,
/// off the main actor, and matched by the name typed after that `/`. Each title is the typed
/// parent followed by the folder's name, and choosing one shows it in the focused pane. Hidden
/// folders are listed only once the typed name starts with a dot, as Finder's Go to Folder
/// does. A streaming source: the parent is listed once while the typed name changes, and the
/// folders found so far are handed over on every key.
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
    private var showsHidden = false

    private final class Parent {
        let typed: String
        let load: ListingLoad
        var items = Items()

        init(typed: String, load: ListingLoad) {
            self.typed = typed
            self.load = load
        }
    }

    /// One listing's folders as items, made on the load's thread.
    struct Items: Sendable {
        var shown: [PaletteItem] = []
        /// `shown` and the hidden folders.
        var all: [PaletteItem] = []
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
        showsHidden = name.hasPrefix(".")
        handOver()
    }

    private func handOver() {
        guard let parent, let deliver else { return }
        deliver(showsHidden ? parent.items.all : parent.items.shown)
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
        let history = history()
        let now = now()
        let focusedPane = focusedPane
        let load = service.load(
            location, priority: .focused,
            prepare: { update -> Items? in
                let listing: Listing
                switch update {
                case .cached(let cached, _, _): listing = cached
                case .firstBatch(let batch, _): listing = batch
                case .full(let full, _): listing = full
                case .failed, .volumeGone: return Items()
                case .slow, .gaveUp: return nil
                }
                return Self.items(
                    in: listing, of: location, typed: typed, history: history, now: now,
                    focusedPane: focusedPane)
            },
            onUpdate: { [weak self] items in
                // A cancelled load hands over nothing more, so this is the parent's load.
                guard let self, let items, let parent = self.parent else { return }
                precondition(parent.typed == typed, "the load of \(typed) outlived its parent")
                parent.items = items
                handOver()
            })
        return Parent(typed: typed, load: load)
    }

    /// The folders of `listing` as items. Runs on the load's thread.
    private nonisolated static func items(
        in listing: Listing, of location: Location, typed: String, history: FolderHistory,
        now: Date, focusedPane: @escaping @MainActor @Sendable () -> Pane
    ) -> Items {
        var items = Items()
        for entry in listing.entries where entry.type == .directory {
            let folder = location.child(named: entry.name)
            let item = PaletteItem(
                id: .folder(path: folder.path), title: typed + entry.name,
                frecency: history.frecency(of: folder, at: now), matchOffset: typed.utf8.count
            ) { focusedPane().navigate(to: folder) }
            items.all.append(item)
            if !entry.isHidden && !entry.name.hasPrefix(".") { items.shown.append(item) }
        }
        return items
    }
}
