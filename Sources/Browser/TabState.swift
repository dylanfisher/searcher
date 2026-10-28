/// A tab as plain values: its layout, with ratios, focus, focus history and zoom, and for each
/// leaf the pane's location, view mode, Back and Forward history, selection by name and sort. The
/// only `Codable` form of a tab; `Pane` itself isn't. It also keeps each pane's column widths, in
/// list mode too, so they come back when the pane shows columns again
/// (0098-column-widths-per-window.md). It leaves out the rows, the filter, hidden files, the
/// scroll offset and the selection history, and, in column mode, every column but the focused
/// one's folder, which is the pane's location.
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
        public let columnWidths: ColumnWidths

        public init(
            location: Location, viewMode: ViewMode, history: History,
            selection: Set<ExactName>, cursor: ExactName?, sortColumn: SortColumn,
            sortAscending: Bool, columnWidths: ColumnWidths
        ) {
            self.location = location
            self.viewMode = viewMode
            self.history = history
            self.selection = selection
            self.cursor = cursor
            self.sortColumn = sortColumn
            self.sortAscending = sortAscending
            self.columnWidths = columnWidths
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

    /// The same tab with each pane's column widths taken from the pane of `other` with its ID;
    /// a pane `other` doesn't have keeps its own.
    public func withColumnWidths(of other: TabState) -> TabState {
        TabState(
            layout: layout,
            panes: Dictionary(
                uniqueKeysWithValues: panes.map { id, pane in
                    let widths = other.panes[id]?.columnWidths ?? pane.columnWidths
                    return (
                        id,
                        PaneState(
                            location: pane.location, viewMode: pane.viewMode,
                            history: pane.history, selection: pane.selection, cursor: pane.cursor,
                            sortColumn: pane.sortColumn, sortAscending: pane.sortAscending,
                            columnWidths: widths)
                    )
                }))
    }

    /// The same tab with each pane's Back and Forward passed through `transform`.
    public func withHistories(_ transform: (History) -> History) -> TabState {
        TabState(
            layout: layout,
            panes: panes.mapValues { pane in
                PaneState(
                    location: pane.location, viewMode: pane.viewMode,
                    history: transform(pane.history), selection: pane.selection,
                    cursor: pane.cursor, sortColumn: pane.sortColumn,
                    sortAscending: pane.sortAscending, columnWidths: pane.columnWidths)
            })
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case layout, panes
    }

    /// A pane as stored: the layout's order, so the same tab always encodes the same way. Its
    /// location, as each stored location, is a folder's `path` or a server's `server`, never both
    /// (`location(path:server:codingPath:)`).
    private struct StoredPane: Codable {
        let id: PaneID
        let path: String?
        let server: String?
        let viewMode: ViewMode
        let back: [StoredEntry]
        let forward: [StoredEntry]
        /// Sorted by UTF-8 bytes, for the same reason.
        let selection: [String]
        let cursor: String?
        let sortColumn: SortColumn
        let sortAscending: Bool
        /// Left out when no width was set, so a pane whose widths were never set stores what a
        /// file without widths holds.
        let columnWidths: StoredColumnWidths?
    }

    private struct StoredColumnWidths: Codable {
        /// Set longest ago first.
        let folders: [StoredFolderWidth]
        let preview: Double?
    }

    private struct StoredFolderWidth: Codable {
        let path: String?
        let server: String?
        let width: Double
    }

    private struct StoredEntry: Codable {
        let path: String?
        let server: String?
        let selected: String?

        init(_ entry: History.Entry) {
            (path, server) = TabState.stored(entry.location)
            selected = entry.selected?.name
        }

        func entry(codingPath: [any CodingKey]) throws -> History.Entry {
            History.Entry(
                location: try TabState.location(path: path, server: server, codingPath: codingPath),
                selected: selected.map(ExactName.init))
        }
    }

    /// `location` as stored: a folder's path, or a server's host as it is written.
    private static func stored(_ location: Location) -> (path: String?, server: String?) {
        switch location {
        case .folder(let path): (path, nil)
        case .server(let server): (nil, server.host)
        }
    }

    /// The location stored as `path` or `server`. Both or neither, a path that isn't absolute,
    /// the empty one among them, or a host that names no server, throws, which rejects the whole
    /// workspace, as other data it can't decode does.
    private static func location(path: String?, server: String?, codingPath: [any CodingKey])
        throws -> Location
    {
        func broken(_ reason: String) -> DecodingError {
            .dataCorrupted(.init(codingPath: codingPath, debugDescription: reason))
        }
        switch (path, server) {
        case (let path?, nil):
            guard path.hasPrefix("/") else {
                throw broken("the stored path \"\(path)\" isn't absolute")
            }
            return Location(path: path)
        case (nil, let host?):
            guard let server = Server(host: host) else {
                throw broken("the stored server \"\(host)\" names no server")
            }
            return .server(server)
        case (.some, .some):
            throw broken("a location stores both a path and a server")
        case (nil, nil):
            throw broken("a location stores neither a path nor a server")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(layout, forKey: .layout)
        let stored = layout.panes.map { id in
            guard let pane = panes[id] else { preconditionFailure("pane \(id) has no state") }
            let (path, server) = Self.stored(pane.location)
            return StoredPane(
                id: id, path: path, server: server, viewMode: pane.viewMode,
                back: pane.history.backEntries.map(StoredEntry.init),
                forward: pane.history.forwardEntries.map(StoredEntry.init),
                selection: pane.selection.map(\.name).sorted {
                    $0.utf8.lexicographicallyPrecedes($1.utf8)
                },
                cursor: pane.cursor?.name, sortColumn: pane.sortColumn,
                sortAscending: pane.sortAscending,
                columnWidths: pane.columnWidths.isEmpty
                    ? nil
                    : StoredColumnWidths(
                        folders: pane.columnWidths.folders.map {
                            let (path, server) = Self.stored($0.location)
                            return StoredFolderWidth(path: path, server: server, width: $0.width)
                        },
                        preview: pane.columnWidths.preview))
        }
        try container.encode(stored, forKey: .panes)
    }

    /// Stored data whose panes don't match the layout's leaves is rejected, not repaired. A
    /// pane's column widths that `ColumnWidths.problem` finds wrong, or that are stored empty, are
    /// dropped, and the pane keeps the rest: the pane shows the default width, as it would with
    /// none set. Each drop is added to the `DroppedColumnWidths` in the decoder's `userInfo`, if
    /// any (0098-column-widths-per-window.md).
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
        let codingPath = decoder.codingPath + [CodingKeys.panes]
        let widths = try stored.enumerated().map { index, pane -> ColumnWidths in
            guard let stored = pane.columnWidths else { return ColumnWidths() }
            let folders = try stored.folders.map {
                ColumnWidths.Folder(
                    location: try Self.location(
                        path: $0.path, server: $0.server, codingPath: codingPath),
                    width: $0.width)
            }
            let problem =
                folders.isEmpty && stored.preview == nil
                ? "column widths are stored with none in them"
                : ColumnWidths.problem(folders: folders, preview: stored.preview)
            if let problem {
                (decoder.userInfo[DroppedColumnWidths.key] as? DroppedColumnWidths)?.add(
                    panes: decoder.codingPath + [CodingKeys.panes], index: index,
                    reason: "pane \(pane.id): \(problem)")
                return ColumnWidths()
            }
            return ColumnWidths(folders: folders, preview: stored.preview)
        }
        panes = Dictionary(
            uniqueKeysWithValues: try zip(stored, widths).map { pane, columnWidths in
                let history = History(
                    back: try pane.back.map { try $0.entry(codingPath: codingPath) },
                    forward: try pane.forward.map { try $0.entry(codingPath: codingPath) })
                let location = try Self.location(
                    path: pane.path, server: pane.server, codingPath: codingPath)
                return (
                    pane.id,
                    PaneState(
                        location: location, viewMode: pane.viewMode, history: history,
                        selection: Set(pane.selection.map(ExactName.init)),
                        cursor: pane.cursor.map(ExactName.init), sortColumn: pane.sortColumn,
                        sortAscending: pane.sortAscending, columnWidths: columnWidths)
                )
            })
    }
}
