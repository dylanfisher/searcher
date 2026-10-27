import Base
import Foundation

/// Go to Item's items: the rows a pane shows, in its order, from the listing it has when the
/// palette opens, so hidden entries and the filter are as the pane shows them and nothing is
/// read from disk. In column view they are the focused column's rows, then the rows of the folder
/// selected in it, as its column right of it lists them, if it has listed. Each is titled with
/// the entry's name and its kind beside it, with "in" and the folder for the selected folder's
/// rows; choosing one selects it where it is listed with its row in the middle of the view
/// (`Pane.jump(to:)`, `ColumnTrail.jump(to:inColumnOf:)`).
///
/// A streaming source. The items are prepared off the main actor once, as the palette opens,
/// and handed over on every key after that. Until they are, it hands over the first
/// `Palette.limit` rows, made on the main actor, which is all an empty query lists
/// (docs/decisions/0101-go-to-item.md).
@MainActor
public final class EntrySource: PaletteSource {
    /// The items made so far: the first rows, then every row.
    private var items: [PaletteItem]
    /// Makes every row's item, off the main actor; nil when the first rows were all.
    private(set) var preparing: Task<[PaletteItem], Never>?
    /// Takes `preparing`'s items and hands them over, unless the palette closed first, which
    /// cancels it. Tests wait on it.
    private(set) var handOver: Task<Void, Never>?
    /// Hands over the items for the latest query; nil once the palette closed.
    private var deliver: (@MainActor ([PaletteItem]) -> Void)?

    /// The names of the folders whose rows are listed: the focused column's, or the pane's, then
    /// the folder selected in it when its column is listed right of it.
    public let folderNames: [String]

    /// One listing's rows: the focused column's, or the pane's, or the selected folder's, whose
    /// items name `folder` in their detail.
    private struct Part: Sendable {
        let listing: Listing
        let folder: String?
        let jump: @MainActor @Sendable (String) -> Void
    }

    /// `pane`'s rows as they are now, or in column view its focused column's, followed by the
    /// rows of the folder selected there when its column is listed right of it. A chosen row is
    /// selected where it is listed; one in the selected folder's column moves the keys into that
    /// column.
    public init(pane: Pane) {
        let focused = pane.commandPane
        var names = [focused.location.name]
        var parts: [Part] = []
        if let listing = focused.state.listing {
            parts.append(
                Part(listing: listing, folder: nil) { [weak focused] name in
                    focused?.jump(to: name)
                })
        }
        if let trail = pane.columnTrail, let next = trail.selectedFolderColumn,
            let listing = next.state.listing
        {
            let folder = next.location.name
            names.append(folder)
            parts.append(
                Part(listing: listing, folder: folder) { [weak trail, weak next] name in
                    guard let trail, let next else { return }
                    trail.jump(to: name, inColumnOf: next)
                })
        }
        folderNames = names
        let count = parts.reduce(0) { $0 + $1.listing.count }
        items = Self.items(in: parts, upTo: min(count, Palette.limit))
        guard count > Palette.limit else { return }
        let preparing = Task.detached(priority: .userInitiated) {
            Self.items(in: parts, upTo: count)
        }
        self.preparing = preparing
        handOver = Task { [weak self] in
            let items = await preparing.value
            // A cancelled preparation returns no items; the first rows stay.
            guard let self, !Task.isCancelled else { return }
            self.items = items
            deliver?(items)
        }
    }

    public func gather(_ query: String, deliver: @escaping @MainActor ([PaletteItem]) -> Void) {
        self.deliver = deliver
        deliver(items)
    }

    public func cancel() {
        preparing?.cancel()
        handOver?.cancel()
        deliver = nil
    }

    /// The items of the first `count` rows of `parts`, in order; none once the task making them
    /// is cancelled, since nothing will show them.
    nonisolated private static func items(in parts: [Part], upTo count: Int) -> [PaletteItem] {
        var items: [PaletteItem] = []
        items.reserveCapacity(count)
        for part in parts {
            let listing = part.listing
            for row in 0..<min(listing.count, count - items.count) {
                if row % 1_024 == 0, Task.isCancelled { return [] }
                let name = listing[row].name
                let kind = listing.kind(atRow: row)
                let jump = part.jump
                items.append(
                    PaletteItem(
                        id: .entry(name: name, isInSelectedFolder: part.folder != nil),
                        title: name,
                        detail: part.folder.map { "\(kind.text) in \($0)" } ?? kind.text,
                        iconType: kind.type
                    ) { jump(name) })
            }
        }
        return items
    }
}
