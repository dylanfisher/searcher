/// A tab as plain values: its layout, with ratios, focus, focus history and zoom, and for each
/// leaf the pane's location, view mode, Back and Forward history, selection by name and sort. The
/// only `Codable` form of a tab; `Pane` itself isn't. It leaves out the rows, the filter, hidden
/// files, the scroll offset and the selection history, and, in column mode, every column but the
/// focused one's folder, which is the pane's location.
public struct TabState: Codable, Equatable, Sendable {
    public struct PaneState: Equatable, Sendable {
        public let location: Location
        public let viewMode: ViewMode
        public let history: History
        /// The selected entries' names. A name no longer in the folder is dropped on restore.
        public let selection: Set<ExactName>
        public let cursor: ExactName?
        public let sortColumn: SortColumn
        public let sortAscending: Bool

        public init(
            location: Location, viewMode: ViewMode, history: History,
            selection: Set<ExactName>, cursor: ExactName?, sortColumn: SortColumn,
            sortAscending: Bool
        ) {
            self.location = location
            self.viewMode = viewMode
            self.history = history
            self.selection = selection
            self.cursor = cursor
            self.sortColumn = sortColumn
            self.sortAscending = sortAscending
        }
    }

    public let layout: Layout
    /// One for each of the layout's panes.
    public let panes: [PaneID: PaneState]

    /// - Precondition: `panes` has a state for each of the layout's panes and no other.
    public init(layout: Layout, panes: [PaneID: PaneState]) {
        precondition(
            Set(panes.keys) == Set(layout.panes), "the pane states don't match the layout's leaves")
        self.layout = layout
        self.panes = panes
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case layout, panes
    }

    /// A pane as stored: the layout's order, so the same tab always encodes the same way.
    private struct StoredPane: Codable {
        let id: PaneID
        let path: String
        let viewMode: StoredViewMode
        let back: [StoredEntry]
        let forward: [StoredEntry]
        /// Sorted by UTF-8 bytes, for the same reason.
        let selection: [String]
        let cursor: String?
        let sortColumn: StoredSortColumn
        let sortAscending: Bool
    }

    private enum StoredViewMode: String, Codable {
        case list, column
    }

    private enum StoredSortColumn: String, Codable {
        case name, size, dateModified, kind
    }

    private struct StoredEntry: Codable {
        let path: String
        let selected: String?

        init(_ entry: History.Entry) {
            path = entry.location.path
            selected = entry.selected?.name
        }

        var entry: History.Entry {
            History.Entry(location: Location(path: path), selected: selected.map(ExactName.init))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(layout, forKey: .layout)
        let stored = layout.panes.map { id in
            guard let pane = panes[id] else { preconditionFailure("pane \(id) has no state") }
            let viewMode: StoredViewMode =
                switch pane.viewMode {
                case .list: .list
                case .column: .column
                }
            let sortColumn: StoredSortColumn =
                switch pane.sortColumn {
                case .name: .name
                case .size: .size
                case .dateModified: .dateModified
                case .kind: .kind
                }
            return StoredPane(
                id: id, path: pane.location.path, viewMode: viewMode,
                back: pane.history.backEntries.map(StoredEntry.init),
                forward: pane.history.forwardEntries.map(StoredEntry.init),
                selection: pane.selection.map(\.name).sorted {
                    $0.utf8.lexicographicallyPrecedes($1.utf8)
                },
                cursor: pane.cursor?.name, sortColumn: sortColumn,
                sortAscending: pane.sortAscending)
        }
        try container.encode(stored, forKey: .panes)
    }

    /// Stored data whose panes don't match the layout's leaves is rejected, not repaired.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layout = try container.decode(Layout.self, forKey: .layout)
        let stored = try container.decode([StoredPane].self, forKey: .panes)
        let ids = stored.map(\.id)
        guard ids.count == Set(ids).count, Set(ids) == Set(layout.panes) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "the panes don't match the layout's leaves"))
        }
        panes = Dictionary(
            uniqueKeysWithValues: stored.map { pane in
                let viewMode: ViewMode =
                    switch pane.viewMode {
                    case .list: .list
                    case .column: .column
                    }
                let sortColumn: SortColumn =
                    switch pane.sortColumn {
                    case .name: .name
                    case .size: .size
                    case .dateModified: .dateModified
                    case .kind: .kind
                    }
                let history = History(
                    back: pane.back.map(\.entry), forward: pane.forward.map(\.entry))
                return (
                    pane.id,
                    PaneState(
                        location: Location(path: pane.path), viewMode: viewMode, history: history,
                        selection: Set(pane.selection.map(ExactName.init)),
                        cursor: pane.cursor.map(ExactName.init), sortColumn: sortColumn,
                        sortAscending: pane.sortAscending)
                )
            })
    }
}
