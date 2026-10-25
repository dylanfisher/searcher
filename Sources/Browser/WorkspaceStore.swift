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
    private let startWait: @Sendable (Duration) -> @Sendable () async throws -> Void
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
        startWait = { duration in
            let deadline = clock.now.advanced(by: duration)
            return { try await clock.sleep(until: deadline, tolerance: nil) }
        }
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
        deleteFile(url(for: id))
    }

    /// Deletes the file of saved workspace `id`'s snapshot and drops a save of it not yet
    /// written, as `delete` does for a window's.
    public func deleteSnapshot(_ id: UUID) {
        pendingSnapshots[id] = nil
        deleteFile(snapshotURL(for: id))
    }

    private func deleteFile(_ url: URL) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            report(StoreProblem(file: url, kind: .unforgotten, reason: "\(error)"))
        }
    }

    private func scheduleWrite() {
        guard scheduledWrite == nil else { return }
        let wait = startWait(Self.writeDelay)
        scheduledWrite = Task {
            do {
                try await wait()
            } catch is CancellationError {
                return
            } catch {
                preconditionFailure("the clock failed a wait with \(error)")
            }
            // A flush between the wait's end and this point cancelled it; both run on the actor.
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    /// Writes every save not yet written, at once, as quitting needs.
    public func flush() {
        dispatchPrecondition(condition: .notOnQueue(.main))
        scheduledWrite?.cancel()
        scheduledWrite = nil
        let workspaces = pending
        let snapshots = pendingSnapshots
        let session = pendingSession
        let folderHistory = pendingFolderHistory
        pending = [:]
        pendingSnapshots = [:]
        pendingSession = nil
        pendingFolderHistory = nil
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
                report(StoreProblem(file: url, kind: .unwritten, reason: "\(error)"))
            }
            return
        }
        for (id, workspace) in workspaces {
            store(workspace, to: url(for: id))
        }
        for (id, snapshot) in snapshots {
            store(snapshot, to: snapshotURL(for: id))
        }
        if let session {
            store(session, to: sessionFile)
        }
        if let folderHistory {
            store(folderHistory, to: folderHistoryFile)
        }
    }

    private func store(_ value: some Encodable, to url: URL) {
        do {
            try write(Self.encoder.encode(value), url)
        } catch {
            report(StoreProblem(file: url, kind: .unwritten, reason: "\(error)"))
        }
    }

    /// The session, every window's workspace and every snapshot: the latest saves, written or
    /// not. A file that isn't in the one stored shape, a workspace file not named for its
    /// workspace's ID, and a snapshot without a name are deleted and reported, and load as
    /// missing. In the workspaces and snapshots folders, an unfinished write left by a crash is
    /// deleted without a report, and other dot-files are left alone. The session is returned as
    /// saved, even when it names a workspace that didn't load.
    public func load() -> Contents {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let workspaces = readWorkspaces(in: folder, at: url(for:)).merging(pending) { _, new in
            new
        }
        var snapshots = readWorkspaces(in: snapshotFolder, at: snapshotURL(for:))
        for (id, snapshot) in snapshots where snapshot.name == nil {
            snapshots[id] = nil
            discard(snapshotURL(for: id), because: "it has no name, which a saved workspace has")
        }
        snapshots.merge(pendingSnapshots) { _, new in new }
        let session = pendingSession ?? read(SessionState.self, from: sessionFile)
        return Contents(session: session, workspaces: workspaces, snapshots: snapshots)
    }

    /// The workspaces in `folder`, each of whose files must be at `url(id)`.
    private func readWorkspaces(in folder: URL, at url: (UUID) -> URL) -> [UUID: WorkspaceState] {
        var workspaces: [UUID: WorkspaceState] = [:]
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
            guard file == url(workspace.id) else {
                discard(file, because: "it holds workspace \(workspace.id)")
                continue
            }
            workspaces[workspace.id] = workspace
        }
        return workspaces
    }

    /// The latest saved folder history, written or not; an empty one when there is none, or when
    /// its file isn't in the one stored shape, which deletes it and reports it.
    public func loadFolderHistory() -> FolderHistory {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return pendingFolderHistory ?? read(FolderHistory.self, from: folderHistoryFile)
            ?? FolderHistory()
    }

    /// The file at `url`, decoded; nil when there is none or it can't be read, and when it isn't
    /// exactly what its decoded value encodes to, which deletes it. That comparison catches a
    /// key a type doesn't declare, which decoding alone ignores, anywhere in the file. A pane's
    /// column widths of another shape are dropped alone: the rest loads, and the file is written
    /// again without them and reported (0098-column-widths-per-window.md).
    private func read<Value: Codable>(_ type: Value.Type, from url: URL) -> Value? {
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
            let encoded = try Self.encoder.encode(value)
            let expected = try JSONSerialization.jsonObject(with: encoded)
            var stored = try JSONSerialization.jsonObject(with: data)
            if !dropped.reasons.isEmpty {
                stored = Self.removing("columnWidths", absentFrom: expected, in: stored)
            }
            guard let stored = stored as? NSObject, stored.isEqual(expected) else {
                discard(url, because: "it has keys or values its \(type) doesn't keep")
                return nil
            }
            if !dropped.reasons.isEmpty {
                // Written back without them, so they are dropped and reported once.
                store(value, to: url)
                report(
                    StoreProblem(
                        file: url, kind: .widthsDropped,
                        reason: dropped.reasons.joined(separator: "; ")))
            }
            return value
        } catch {
            discard(url, because: "\(error)")
            return nil
        }
    }

    /// `stored`, a decoded JSON value, without each `key` that the same place in `expected` lacks,
    /// so a file whose column widths a decode dropped still has every other key checked.
    private static func removing(_ key: String, absentFrom expected: Any, in stored: Any) -> Any {
        if let stored = stored as? [String: Any], let expected = expected as? [String: Any] {
            var kept: [String: Any] = [:]
            for (name, value) in stored {
                guard let match = expected[name] else {
                    if name != key { kept[name] = value }
                    continue
                }
                kept[name] = removing(key, absentFrom: match, in: value)
            }
            return kept
        }
        if let stored = stored as? [Any], let expected = expected as? [Any],
            stored.count == expected.count
        {
            return zip(stored, expected).map { removing(key, absentFrom: $1, in: $0) }
        }
        return stored
    }

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
