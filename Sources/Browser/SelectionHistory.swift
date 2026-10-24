import Base

/// A pane's selection undo, after Sublime Text's soft undo: each change of the selection in a
/// folder keeps the selection before it, Undo Selection steps back through them and Redo
/// Selection forward again, and a new change ends the way forward. It never holds file changes;
/// those are `UndoHistory`'s (docs/decisions/0077-selection-history.md).
///
/// Each folder has its own steps, kept for the `folderLimit` folders changed most recently, so a
/// step never takes the pane to another folder. A run of changes from one source, each within
/// `runInterval` of the last, is one step: a held arrow key, a type-to-select query, one mouse
/// press. A selection with nothing selected and no cursor isn't a step.
public struct SelectionHistory {
    /// The steps kept per folder; the oldest goes first.
    public static let limit = 100
    /// The folders whose steps are kept; the one changed longest ago goes first.
    public static let folderLimit = 20
    /// The longest pause inside a run, the same as type-to-select's, so a query is one run.
    public static let runInterval = TypeSelect.resetInterval

    /// What made a change, for joining a run into one step.
    public enum Source: Equatable, Sendable {
        /// Never joins a run, such as Select All or a selection a command makes.
        case once
        /// A row key's move, repeated while the key is held.
        case move(by: Int, extending: Bool)
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
    /// Time on the injected clock since this was made; erases the clock's type, as `TypeSelect`.
    private let elapsed: @Sendable () -> Duration

    public init() {
        self.init(clock: ContinuousClock())
    }

    /// Measures runs on `clock`. Tests pass a clock they advance by hand.
    public init<C: Clock>(clock: C) where C.Duration == Duration {
        let start = clock.now
        elapsed = { start.duration(to: clock.now) }
    }

    public func canUndo(in folder: Location) -> Bool {
        !(folders[folder.path]?.back.isEmpty ?? true)
    }

    public func canRedo(in folder: Location) -> Bool {
        !(folders[folder.path]?.forward.isEmpty ?? true)
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
            source != .once
            && run.map {
                $0.source == source && $0.folder == path && now - $0.at < Self.runInterval
            } ?? false
        if !joinsRun, !previous.isEmpty || previous.cursor != nil,
            steps.back.last != Self.kept(previous)
        {
            steps.back.append(Self.kept(previous))
            if steps.back.count > Self.limit { steps.back.removeFirst() }
        }
        store(steps, at: path)
    }

    /// The selection to go back to from `current` in `folder`, which becomes the way forward;
    /// nil with no step back.
    public mutating func undo(_ current: Selection, in folder: Location) -> Selection? {
        guard var steps = folders[folder.path], let step = steps.back.popLast() else { return nil }
        steps.forward.append(Self.kept(current))
        store(steps, at: folder.path)
        run = nil
        return step
    }

    /// The selection the last undo in `folder` stepped back from, with `current` the way back
    /// again; nil with no step forward.
    public mutating func redo(_ current: Selection, in folder: Location) -> Selection? {
        guard var steps = folders[folder.path], let step = steps.forward.popLast() else {
            return nil
        }
        steps.back.append(Self.kept(current))
        store(steps, at: folder.path)
        run = nil
        return step
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
    /// keep a copy of an old listing alive per step. An unsettled selection is kept as it is,
    /// since naming its rows here would be work per entry on the main thread; it is resolved
    /// when restored.
    private static func kept(_ selection: Selection) -> Selection {
        guard selection.isSettled else { return selection }
        return Selection(selection.members, cursor: selection.cursor, anchor: selection.anchor)
    }
}
