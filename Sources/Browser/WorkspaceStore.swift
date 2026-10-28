import Base
import Foundation

/// Keeps workspaces and the session on disk: one JSON file per open window's workspace in
/// `<application support root>/workspaces/<id>.json`, one per saved workspace's snapshot in
/// `<application support root>/snapshots/<id>.json`, the open windows in
/// `<application support root>/session.json`, and the palette's `FolderHistory` in
/// `<application support root>/folder-history.json`. Saves are written `writeDelay` after the first
/// unwritten one, so a burst of edits costs one write per file, each through `AtomicWrite`. A
/// file that isn't in the one stored shape is deleted and reported, and the rest still load. See
/// docs/decisions/0078-workspace-store.md and docs/decisions/0088-workspace-snapshots.md.
public actor WorkspaceStore {
    /// How long after the first unwritten save the store writes.
    public static let writeDelay: Duration = .seconds(1)

    /// What a load finds.
    public struct Contents: Equatable, Sendable {
        public let session: SessionState?
        /// The open windows' workspaces, as last saved, by ID.
        public let workspaces: [UUID: WorkspaceState]
        /// The saved workspaces' snapshots, by ID; each has a name.
        public let snapshots: [UUID: WorkspaceState]

        public init(
            session: SessionState?, workspaces: [UUID: WorkspaceState],
            snapshots: [UUID: WorkspaceState]
        ) {
            self.session = session
            self.workspaces = workspaces
            self.snapshots = snapshots
        }
    }

    private let folder: URL
    private let snapshotFolder: URL
    private let sessionFile: URL
    private let folderHistoryFile: URL
    private let report: @Sendable (StoreProblem) -> Void
    /// Starts a wait of the given length on the store's clock, taking the deadline at once.
    private let startWait: DeadlineWait.Start
    private let write: @Sendable (Data, URL) throws -> Void
    /// Workspaces not yet written, by ID.
    private var pending: [UUID: WorkspaceState] = [:]
    /// Snapshots not yet written, by ID.
    private var pendingSnapshots: [UUID: WorkspaceState] = [:]
    private var pendingSession: SessionState?
    private var pendingFolderHistory: FolderHistory?
    /// The wait for the next write, cancelled by a `flush` that writes first, so a save after
    /// the flush waits the whole delay.
    private var scheduledWrite: Task<Void, Never>?
    /// The files whose last write failed and was reported. Their next failures aren't reported
    /// again until a write of them succeeds, so a full disk shows one problem per file, not one
    /// per retry.
    private var unwritten: Set<URL> = []

    /// A store in `roots.applicationSupport`. `report` gets each file that couldn't be read,
    /// written or decoded. `write` replaces a file's contents; tests pass one that records its
    /// calls.
    public init<C: Clock<Duration>>(
        roots: StoreRoots, report: @escaping @Sendable (StoreProblem) -> Void,
        clock: C = ContinuousClock(),
        write: @escaping @Sendable (Data, URL) throws -> Void = {
            try AtomicWrite.write($0, to: $1)
        }
    ) {
        folder = roots.applicationSupport.appending(path: "workspaces")
        snapshotFolder = roots.applicationSupport.appending(path: "snapshots")
        sessionFile = roots.applicationSupport.appending(path: "session.json")
        folderHistoryFile = roots.applicationSupport.appending(path: "folder-history.json")
        self.report = report
        startWait = DeadlineWait.make(on: clock)
        self.write = write
    }

    /// Saves `workspace`, an open window's, replacing what was saved under its ID.
    public func save(_ workspace: WorkspaceState) {
        pending[workspace.id] = workspace
        scheduleWrite()
    }

    /// Saves `snapshot`, a saved workspace's, replacing the snapshot saved under its ID.
    public func saveSnapshot(_ snapshot: WorkspaceState) {
        pendingSnapshots[snapshot.id] = snapshot
        scheduleWrite()
    }

    /// Saves `session`, replacing the one saved before.
    public func saveSession(_ session: SessionState) {
        pendingSession = session
        scheduleWrite()
    }

    /// Saves `history`, replacing the one saved before.
    public func saveFolderHistory(_ history: FolderHistory) {
        pendingFolderHistory = history
        scheduleWrite()
    }

    /// Deletes workspace `id`'s file and drops a save of it not yet written. A workspace that was
    /// never written has no file, which isn't a problem.
    public func delete(_ id: UUID) {
        pending[id] = nil
        unwritten.remove(url(for: id))
        deleteFile(url(for: id))
    }

    /// Deletes the file of saved workspace `id`'s snapshot and drops a save of it not yet
    /// written, as `delete` does for a window's. Returns whether the file is gone; a failure is
    /// reported as well.
    @discardableResult
    public func deleteSnapshot(_ id: UUID) -> Bool {
        pendingSnapshots[id] = nil
        unwritten.remove(snapshotURL(for: id))
        return deleteFile(snapshotURL(for: id))
    }

    /// Deletes `url`; returns whether it is gone, and reports a failure.
    @discardableResult
    private func deleteFile(_ url: URL) -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return true
        } catch {
            report(StoreProblem(file: url, kind: .unforgotten, reason: "\(error)"))
            return false
        }
    }

    private func scheduleWrite() {
        guard scheduledWrite == nil else { return }
        let wait = startWait(Self.writeDelay)
        scheduledWrite = Task {
            guard await DeadlineWait.reached(wait) else { return }
            // A flush between the wait's end and this point cancelled it; both run on the actor.
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    /// Writes every save not yet written, at once, as quitting needs. A save whose write fails
    /// stays unwritten and a write is scheduled again, `writeDelay` later, so it is retried until
    /// it succeeds, unless a newer save or a delete replaces it. A file's failure is reported
    /// once until a write of it succeeds.
    public func flush() {
        writePending()
        if !pending.isEmpty || !pendingSnapshots.isEmpty || pendingSession != nil
            || pendingFolderHistory != nil
        {
            scheduleWrite()
        }
    }

    private func writePending() {
        dispatchPrecondition(condition: .notOnQueue(.main))
        scheduledWrite?.cancel()
        scheduledWrite = nil
        let workspaces = pending
        let snapshots = pendingSnapshots
        let session = pendingSession
        let folderHistory = pendingFolderHistory
        guard !workspaces.isEmpty || !snapshots.isEmpty || session != nil || folderHistory != nil
        else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: snapshotFolder, withIntermediateDirectories: true)
        } catch {
            // The session and history files sit beside the folders, so they fail with them.
            var files = workspaces.keys.map(url(for:)) + snapshots.keys.map(snapshotURL(for:))
            if session != nil { files.append(sessionFile) }
            if folderHistory != nil { files.append(folderHistoryFile) }
            for url in files {
                reportUnwritten(url, error)
            }
            return
        }
        // Nothing else runs on the actor during a flush, so a save is dropped from the pending
        // ones only once it is written, and one that fails waits for the next flush.
        for (id, workspace) in workspaces where store(workspace, to: url(for: id)) {
            pending[id] = nil
        }
        for (id, snapshot) in snapshots where store(snapshot, to: snapshotURL(for: id)) {
            pendingSnapshots[id] = nil
        }
        if let session, store(session, to: sessionFile) {
            pendingSession = nil
        }
        if let folderHistory, store(folderHistory, to: folderHistoryFile) {
            pendingFolderHistory = nil
        }
    }

    /// Writes `value` to `url`; reports a failure and returns false.
    @discardableResult
    private func store(_ value: some Encodable, to url: URL) -> Bool {
        do {
            try write(Self.encoder.encode(value), url)
            unwritten.remove(url)
            return true
        } catch {
            reportUnwritten(url, error)
            return false
        }
    }

    /// Reports that `url` couldn't be written, unless its last write failed and was reported.
    private func reportUnwritten(_ url: URL, _ error: any Error) {
        guard unwritten.insert(url).inserted else { return }
        report(StoreProblem(file: url, kind: .unwritten, reason: "\(error)"))
    }

    /// The session, every window's workspace and every snapshot: the latest saves, written or
    /// not. A file that isn't in the one stored shape, a workspace file not named for its
    /// workspace's ID, and a snapshot without a name or with window steps are deleted and
    /// reported, and load as missing. In the workspaces and snapshots folders, an unfinished
    /// write left by a crash is deleted without a report, and other dot-files are left alone.
    /// The session is returned as saved, even when it names a workspace that didn't load; with
    /// no session file, or one that didn't load, it is rebuilt from the window files that
    /// loaded.
    public func load() -> Contents {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let workspaces = readWorkspaces(in: folder, at: url(for:))
            .mapValues { kept($0, at: url(for: $0.value.id)) }
            .merging(pending) { _, new in new }
        var snapshots = readWorkspaces(in: snapshotFolder, at: snapshotURL(for:))
        for (id, snapshot) in snapshots where snapshot.value.name == nil {
            snapshots[id] = nil
            discard(snapshotURL(for: id), because: "it has no name, which a saved workspace has")
        }
        for (id, snapshot) in snapshots where !snapshot.value.history.isEmpty {
            snapshots[id] = nil
            discard(
                snapshotURL(for: id),
                because: "it has Back or Forward steps, which only a window keeps")
        }
        let loadedSnapshots = snapshots.mapValues { kept($0, at: snapshotURL(for: $0.value.id)) }
            .merging(pendingSnapshots) { _, new in new }
        let session =
            pendingSession
            ?? read(SessionState.self, from: sessionFile).map {
                kept($0, at: sessionFile)
            } ?? rebuiltSession(of: Array(workspaces.keys))
        return Contents(session: session, workspaces: workspaces, snapshots: loadedSnapshots)
    }

    /// A session of the windows `ids`, for a load whose session file is missing or didn't load,
    /// so their files aren't taken for a crash's leftovers: the window whose file was written
    /// last first, as the key window, and one not yet written before them all. It is saved, so
    /// the next flush writes it. Nil with no window. See docs/decisions/0080-restore-at-launch.md.
    private func rebuiltSession(of ids: [UUID]) -> SessionState? {
        guard !ids.isEmpty else { return nil }
        let written = Dictionary(
            uniqueKeysWithValues: ids.map { id in
                (id, pending[id] == nil ? modified(url(for: id)) : .distantFuture)
            })
        let order = ids.sorted { a, b in
            guard let x = written[a], let y = written[b] else {
                preconditionFailure("workspace \(a) or \(b) has no write date")
            }
            // By ID among equal dates, so the order doesn't depend on the folder's.
            return x == y ? a.uuidString < b.uuidString : x > y
        }
        let session = SessionState(workspaces: order, keyWindow: order[0])
        saveSession(session)
        return session
    }

    /// When the file at `url` was last written. One whose date can't be read, though it was just
    /// read, is reported and counts as the oldest: its window is restored either way, and only
    /// its place in the order is unknown.
    private func modified(_ url: URL) -> Date {
        do {
            guard
                let date = try url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
            else { throw CocoaError(.fileReadUnknown) }
            return date
        } catch {
            report(StoreProblem(file: url, kind: .undated, reason: "\(error)"))
            return .distantPast
        }
    }

    /// The workspaces in `folder`, each of whose files must be at `url(id)`, as read: not yet
    /// written back without the column widths a read dropped.
    private func readWorkspaces(in folder: URL, at url: (UUID) -> URL) -> [UUID: Read<
        WorkspaceState
    >] {
        var workspaces: [UUID: Read<WorkspaceState>] = [:]
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            names = []
        } catch {
            report(StoreProblem(file: folder, kind: .unreadable, reason: "\(error)"))
            names = []
        }
        for name in names {
            let file = folder.appending(path: name)
            if AtomicWrite.isPartial(name) {
                removeLeftover(file)
                continue
            }
            // Such as Finder's .DS_Store, which isn't the store's to delete.
            if name.hasPrefix(".") { continue }
            guard let workspace = read(WorkspaceState.self, from: file) else { continue }
            guard file == url(workspace.value.id) else {
                discard(file, because: "it holds workspace \(workspace.value.id)")
                continue
            }
            workspaces[workspace.value.id] = workspace
        }
        return workspaces
    }

    /// The latest saved folder history, written or not; an empty one when there is none, or when
    /// its file isn't in the one stored shape, which deletes it and reports it.
    public func loadFolderHistory() -> FolderHistory {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return pendingFolderHistory
            ?? read(FolderHistory.self, from: folderHistoryFile).map {
                kept($0, at: folderHistoryFile)
            } ?? FolderHistory()
    }

    /// A file's decoded value, and why each pane's column widths the decode dropped were dropped.
    private struct Read<Value> {
        let value: Value
        let droppedWidths: [String]
    }

    /// `read`'s value, once the file it came from is kept: written back without the column widths
    /// the read dropped, if any, and reported, so they are dropped and reported once. A file the
    /// load deletes for another reason isn't written back first.
    private func kept<Value: Encodable>(_ read: Read<Value>, at url: URL) -> Value {
        if !read.droppedWidths.isEmpty {
            store(read.value, to: url)
            report(
                StoreProblem(
                    file: url, kind: .widthsDropped,
                    reason: read.droppedWidths.joined(separator: "; ")))
        }
        return read.value
    }

    /// The file at `url`, decoded; nil when there is none or it can't be read, and when it isn't
    /// exactly what its decoded value encodes to, which deletes it. That comparison catches a
    /// key a type doesn't declare, which decoding alone ignores, anywhere in the file. A pane's
    /// column widths of another shape are dropped alone: the rest loads, and the comparison
    /// leaves out exactly the `columnWidths` key of each pane whose widths were dropped, located by
    /// its path in the file (0098-column-widths-per-window.md).
    private func read<Value: Codable>(_ type: Value.Type, from url: URL) -> Read<Value>? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            report(StoreProblem(file: url, kind: .unreadable, reason: "\(error)"))
            return nil
        }
        do {
            let dropped = DroppedColumnWidths()
            let decoder = JSONDecoder()
            decoder.userInfo[DroppedColumnWidths.key] = dropped
            let value = try decoder.decode(type, from: data)
            let expected = try JSONSerialization.jsonObject(with: Self.encoder.encode(value))
            var stored = try JSONSerialization.jsonObject(with: data)
            for drop in dropped.drops {
                stored = try Self.removingColumnWidths(at: drop.pane, in: stored)
            }
            guard let stored = stored as? NSObject, stored.isEqual(expected) else {
                discard(url, because: "it has keys or values its \(type) doesn't keep")
                return nil
            }
            return Read(value: value, droppedWidths: dropped.drops.map(\.reason))
        } catch {
            discard(url, because: "\(error)")
            return nil
        }
    }

    /// `json`, a file's decoded JSON, without the `columnWidths` key of the pane object at
    /// `path`: the widths a decode dropped there. Nothing else is removed, so any other
    /// difference from what the value encodes to still fails the comparison.
    private static func removingColumnWidths(
        at path: [DroppedColumnWidths.Step], in json: Any
    ) throws -> Any {
        guard let step = path.first else {
            guard var pane = json as? [String: Any], pane["columnWidths"] != nil else {
                throw droppedWidthsNotFound
            }
            pane["columnWidths"] = nil
            return pane
        }
        let rest = Array(path.dropFirst())
        switch step {
        case .key(let key):
            guard var object = json as? [String: Any], let value = object[key] else {
                throw droppedWidthsNotFound
            }
            object[key] = try removingColumnWidths(at: rest, in: value)
            return object
        case .index(let index):
            guard var array = json as? [Any], array.indices.contains(index) else {
                throw droppedWidthsNotFound
            }
            array[index] = try removingColumnWidths(at: rest, in: array[index])
            return array
        }
    }

    /// A decode reported dropped widths where the file has none, which can't happen with
    /// `JSONDecoder`; the file is discarded rather than kept unchecked.
    private static let droppedWidthsNotFound = DecodingError.dataCorrupted(
        .init(
            codingPath: [],
            debugDescription: "dropped column widths aren't where the decode saw them"))

    /// The file `id`'s window's workspace is kept in.
    nonisolated func url(for id: UUID) -> URL {
        folder.appending(path: "\(id.uuidString).json")
    }

    /// The file saved workspace `id`'s snapshot is kept in.
    nonisolated func snapshotURL(for id: UUID) -> URL {
        snapshotFolder.appending(path: "\(id.uuidString).json")
    }

    /// Deletes a write's temporary file that a crash left. It held nothing the user lost, since
    /// the file it was to replace is still there, so only a failure to delete it is reported.
    private func removeLeftover(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            report(
                StoreProblem(
                    file: url, kind: .undeletable,
                    reason: "it's an unfinished write left by a crash; deleting it failed: \(error)"
                ))
        }
    }

    private func discard(_ url: URL, because reason: String) {
        do {
            try FileManager.default.removeItem(at: url)
            report(StoreProblem(file: url, kind: .discarded, reason: reason))
        } catch {
            report(
                StoreProblem(
                    file: url, kind: .undeletable,
                    reason: "\(reason); deleting it then failed: \(error)"))
        }
    }

    /// Sorted keys, so the same state always writes the same bytes.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}
