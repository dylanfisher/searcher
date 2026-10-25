import Base
import Foundation

/// Go to Item's items: the rows a pane shows, in its order, from the listing it has when the
/// palette opens, so hidden entries and the filter are as the pane shows them and nothing is
/// read from disk. Each is titled with the entry's name and its kind beside it; choosing one
/// selects it in the pane with its row in the middle of the view (`Pane.jump(to:)`).
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
    /// Takes `preparing`'s items and hands them over, unless the palette closed first. Tests
    /// wait on it.
    private(set) var handOver: Task<Void, Never>?
    /// Hands over the items for the latest query; nil once the palette closed.
    private var deliver: (@MainActor ([PaletteItem]) -> Void)?

    /// `pane`'s rows as they are now; a chosen one is selected in `pane`.
    public init(pane: Pane) {
        let jump: @MainActor @Sendable (String) -> Void = { [weak pane] name in
            pane?.jump(to: name)
        }
        guard let listing = pane.state.listing else {
            items = []
            return
        }
        items = Self.items(in: listing, rows: 0..<min(listing.count, Palette.limit), jump: jump)
        guard listing.count > Palette.limit else { return }
        let preparing = Task.detached(priority: .userInitiated) {
            Self.items(in: listing, rows: 0..<listing.count, jump: jump)
        }
        self.preparing = preparing
        handOver = Task { [weak self] in
            let items = await preparing.value
            guard let self else { return }
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
        deliver = nil
    }

    /// The items of `listing`'s `rows`; none once the task making them is cancelled, since
    /// nothing will show them.
    nonisolated private static func items(
        in listing: Listing, rows: Range<Int>, jump: @escaping @MainActor @Sendable (String) -> Void
    ) -> [PaletteItem] {
        var items: [PaletteItem] = []
        items.reserveCapacity(rows.count)
        for row in rows {
            if row % 1_024 == 0, Task.isCancelled { return [] }
            let name = listing[row].name
            let kind = listing.kind(atRow: row)
            items.append(
                PaletteItem(
                    id: .entry(name: name), title: name, detail: kind.text, iconType: kind.type
                ) { jump(name) })
        }
        return items
    }
}
