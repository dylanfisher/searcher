import Base

/// A tab's selection undo, after Sublime Text's soft undo: each change of a selection keeps the
/// position before it, Undo Selection steps back through them and Redo Selection forward again,
/// and a new change ends the way forward. It never holds file changes; those are
/// `UndoHistory`'s (docs/decisions/0077-selection-history.md,
/// docs/decisions/0112-position-history.md).
///
/// A step is a `Position`: the pane, the folder and the selection there. The tab drops a pane's
/// steps when the pane closes, leaves the tab, or goes to another folder other than by moving
/// in its column trail, so a step's folder is one the pane still shows or a column of its trail.
/// A run of changes is one step: the repeats of a held row key after its press, one mouse press
/// however long it lasts, and a type-to-select query until a pause of `queryPause`. Each
/// separate press of a row key is a step of its own. A selection with nothing selected and no
/// cursor isn't a step.
public struct SelectionHistory {
    /// The steps kept per pane; the pane's oldest goes first.
    public static let limit = 100
    /// The pause that ends a type-to-select query, and so its step.
    public static let queryPause = TypeSelect.resetInterval

    /// Where the keys were and what was selected there: the tab's pane, the folder, which in
    /// column view names the column, and the selection, kept by name. Neither a `Pane` nor a
    /// column index: a column's pane goes when its trail closes the column.
    public struct Position: Equatable, Sendable {
        public let pane: PaneID
        public let folder: Location
        public let selection: Selection

        public init(pane: PaneID, folder: Location, selection: Selection) {
            self.pane = pane
            self.folder = folder
            self.selection = selection
        }
    }

    /// What made a change, for joining a run into one step.
    public enum Source: Equatable, Sendable {
        /// Never joins a run, such as Select All or a selection a command makes.
        case once
        /// A row key's move. A repeat, sent while the key is held, joins the move before it when
        /// that was the same key's.
        case move(by: Int, extending: Bool, isRepeat: Bool)
        /// A key typed into a type-to-select query.
        case typing
        /// The changes one mouse press makes in the table, numbered per press.
        case press(Int)
    }

    /// Nearest last.
    private var back: [Position] = []
    /// Nearest last.
    private var forward: [Position] = []
    /// The last change, while another from the same source in the same pane and folder can join
    /// its step.
    private var run: (source: Source, pane: PaneID, folder: Location, at: Duration)?
    /// Time on the injected clock since this was made, for the pause that ends a query; erases
    /// the clock's type, as `TypeSelect` does.
    private let elapsed: @Sendable () -> Duration

    public init() {
        self.init(clock: ContinuousClock())
    }

    /// Measures pauses on `clock`. Tests pass a clock they advance by hand.
    public init<C: Clock>(clock: C) where C.Duration == Duration {
        let start = clock.now
        elapsed = { start.duration(to: clock.now) }
    }

    /// Whether a step back is left that `restorable` accepts; see `undo`.
    public func canUndo(where restorable: (Position) -> Bool = { _ in true }) -> Bool {
        back.contains(where: restorable)
    }

    /// Whether a step forward is left that `restorable` accepts.
    public func canRedo(where restorable: (Position) -> Bool = { _ in true }) -> Bool {
        forward.contains(where: restorable)
    }

    /// Notes that a selection changed from `previous` by `source`. Ends the way forward, and
    /// keeps `previous` as a step unless the change joins the run before it.
    public mutating func record(_ previous: Position, by source: Source) {
        let now = elapsed()
        defer { run = (source, previous.pane, previous.folder, now) }
        forward = []
        let joinsRun =
            run.map {
                $0.pane == previous.pane && $0.folder == previous.folder
                    && Self.joins(source, $0.source, now - $0.at)
            } ?? false
        let step = Self.kept(previous)
        guard !joinsRun, !step.selection.isEmpty || step.selection.cursor != nil,
            back.last != step
        else { return }
        back.append(step)
        if let oldest = back.firstIndex(where: { $0.pane == step.pane }),
            back.count(where: { $0.pane == step.pane }) > Self.limit
        {
            back.remove(at: oldest)
        }
    }

    /// Steps back to the nearest step that `restoring` restores. `restoring` turns a step into
    /// what restores it and the position that restoring it replaces, which becomes the way
    /// forward; or into nil, for a step that would change nothing, such as one whose entries are
    /// all gone, which is dropped on the way. Nil when none is left.
    public mutating func undo<Restore>(
        _ restoring: (Position) -> (Restore, replacing: Position)?
    ) -> Restore? {
        guard let (restore, replaced) = Self.pop(&back, restoring) else { return nil }
        forward.append(Self.kept(replaced))
        run = nil
        return restore
    }

    /// Steps forward to what the last undo stepped back from, as `undo` does.
    public mutating func redo<Restore>(
        _ restoring: (Position) -> (Restore, replacing: Position)?
    ) -> Restore? {
        guard let (restore, replaced) = Self.pop(&forward, restoring) else { return nil }
        back.append(Self.kept(replaced))
        run = nil
        return restore
    }

    /// Drops every step of `pane`, back and forward: it closed, left the tab or went to another
    /// folder, so its steps name folders it no longer shows.
    public mutating func dropSteps(of pane: PaneID) {
        back.removeAll { $0.pane == pane }
        forward.removeAll { $0.pane == pane }
        if run?.pane == pane { run = nil }
    }

    /// Pops `steps` down to the nearest one `restoring` turns into something, and returns that.
    private static func pop<Restore>(
        _ steps: inout [Position], _ restoring: (Position) -> (Restore, replacing: Position)?
    ) -> (Restore, replacing: Position)? {
        while let step = steps.popLast() {
            if let found = restoring(step) { return found }
        }
        return nil
    }

    /// Whether a change from `source` joins the run of the last one, from `last` `pause` ago.
    private static func joins(_ source: Source, _ last: Source, _ pause: Duration) -> Bool {
        switch (source, last) {
        case (.move(let by, let extending, true), .move(let lastBy, let lastExtending, _)):
            by == lastBy && extending == lastExtending
        case (.press(let press), .press(let lastPress)):
            press == lastPress
        case (.typing, .typing):
            pause < queryPause
        default:
            false
        }
    }

    /// `position` as a step keeps it: its selection by name, without the listing Select All saw,
    /// which would keep a copy of an old listing alive per step. An unsettled selection, rare
    /// since one settles within milliseconds, is kept as it is and named when restored.
    private static func kept(_ position: Position) -> Position {
        let selection = position.selection
        guard selection.isSettled else { return position }
        return Position(
            pane: position.pane, folder: position.folder,
            selection: Selection(
                selection.members, cursor: selection.cursor, anchor: selection.anchor))
    }
}
