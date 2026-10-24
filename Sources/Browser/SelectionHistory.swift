import Base

/// A pane's selection undo, after Sublime Text's soft undo: each change of the selection in a
/// folder keeps the selection before it, Undo Selection steps back through them and Redo
/// Selection forward again, and a new change ends the way forward. It never holds file changes;
/// those are `UndoHistory`'s (docs/decisions/0077-selection-history.md).
///
/// Each folder has its own steps, kept for the `folderLimit` folders changed most recently, so a
/// step never takes the pane to another folder. A run of changes is one step: the repeats of a
/// held row key after its press, one mouse press however long it lasts, and a type-to-select
/// query until a pause of `queryPause`. Each separate press of a row key is a step of its own. A
/// selection with nothing selected and no cursor isn't a step.
public struct SelectionHistory {
    /// The steps kept per folder; the oldest goes first.
    public static let limit = 100
    /// The folders whose steps are kept; the one changed longest ago goes first.
    public static let folderLimit = 20
    /// The pause that ends a type-to-select query, and so its step.
    public static let queryPause = TypeSelect.resetInterval

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

    private struct Steps {
        /// Nearest last.
        var back: [Selection] = []
        /// Nearest last.
        var forward: [Selection] = []
    }

    /// By folder path.
    private var folders: [String: Steps] = [:]
    /// Folder paths, the one changed longest ago first.
    private var recent: [String] = []
    /// The last change, while another from the same source can join its step.
    private var run: (source: Source, folder: String, at: Duration)?
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

    /// Whether `folder` has a step back that `restoring` turns into a selection; see `undo`.
    public func canUndo(
        in folder: Location, restoring: (Selection) -> Selection? = { $0 }
    ) -> Bool {
        folders[folder.path]?.back.contains { restoring($0) != nil } ?? false
    }

    /// Whether `folder` has a step forward that `restoring` turns into a selection.
    public func canRedo(
        in folder: Location, restoring: (Selection) -> Selection? = { $0 }
    ) -> Bool {
        folders[folder.path]?.forward.contains { restoring($0) != nil } ?? false
    }

    /// Notes that the selection in `folder` changed from `previous` by `source`. Ends the way
    /// forward, and keeps `previous` as a step unless the change joins the run before it.
    public mutating func record(_ previous: Selection, in folder: Location, by source: Source) {
        let path = folder.path
        let now = elapsed()
        defer { run = (source, path, now) }
        var steps = folders[path] ?? Steps()
        steps.forward = []
        let joinsRun =
            run.map { $0.folder == path && Self.joins(source, $0.source, now - $0.at) }
            ?? false
        if !joinsRun, !previous.isEmpty || previous.cursor != nil,
            steps.back.last != Self.kept(previous)
        {
            steps.back.append(Self.kept(previous))
            if steps.back.count > Self.limit { steps.back.removeFirst() }
        }
        store(steps, at: path)
    }

    /// The selection to go back to from `current` in `folder`: the nearest step back that
    /// `restoring` turns into a selection, as it turns it. `current` becomes the way forward.
    /// Steps it turns into nothing, such as ones whose entries are all gone, are dropped on the
    /// way. Nil when none is left.
    public mutating func undo(
        _ current: Selection, in folder: Location,
        restoring: (Selection) -> Selection? = { $0 }
    ) -> Selection? {
        guard var steps = folders[folder.path] else { return nil }
        defer { store(steps, at: folder.path) }
        while let step = steps.back.popLast() {
            guard let restored = restoring(step) else { continue }
            steps.forward.append(Self.kept(current))
            run = nil
            return restored
        }
        return nil
    }

    /// The selection the last undo in `folder` stepped back from, as `undo` finds it, with
    /// `current` the way back again.
    public mutating func redo(
        _ current: Selection, in folder: Location,
        restoring: (Selection) -> Selection? = { $0 }
    ) -> Selection? {
        guard var steps = folders[folder.path] else { return nil }
        defer { store(steps, at: folder.path) }
        while let step = steps.forward.popLast() {
            guard let restored = restoring(step) else { continue }
            steps.back.append(Self.kept(current))
            run = nil
            return restored
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

    private mutating func store(_ steps: Steps, at path: String) {
        folders[path] = steps
        recent.removeAll { $0 == path }
        recent.append(path)
        if recent.count > Self.folderLimit {
            folders[recent.removeFirst()] = nil
        }
    }

    /// `selection` as a step keeps it: by name, without the listing Select All saw, which would
    /// keep a copy of an old listing alive per step. An unsettled selection, rare since one
    /// settles within milliseconds, is kept as it is and named when restored.
    private static func kept(_ selection: Selection) -> Selection {
        guard selection.isSettled else { return selection }
        return Selection(selection.members, cursor: selection.cursor, anchor: selection.anchor)
    }
}
