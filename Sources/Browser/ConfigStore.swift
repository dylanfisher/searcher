import Base
import Foundation

/// Reads the config file, reads it again after each change in its folder, and writes what
/// `Settings` hands it, all off the main actor (docs/decisions/0123-config-is-the-settings.md).
/// It watches the folder rather than the file, since an editor's atomic save, and Dropbox's,
/// replaces the file; and the folder may not exist yet: FSEvents matches the path of each
/// change, so changes arrive once the folder is made.
///
/// Each read is compared with the file as last read or written, byte for byte, so the store's
/// own write, a save that changes nothing and another file changing in the folder send nothing.
/// Each read it sends has the next generation; a write based on an earlier one is dropped, so
/// a change made in the app never replaces an edit of the file it hadn't seen. A file that has
/// an error is never written over. A read that finds the file empty or gone is sent only once a
/// second read `confirmDelay` later still finds it so, since an editor's save in place and a
/// sync tool's delete and create pass through both.
public actor ConfigStore {
    /// Starts watching `folder`, calling `onChange` after each batch of changes in it, and
    /// returns what stops the watch.
    public typealias Watch =
        @Sendable (_ folder: String, _ onChange: @escaping @Sendable () -> Void) throws
        -> @Sendable () -> Void
    /// Replaces the file at the URL with the data, running the check between writing the data
    /// aside and the rename that puts it in place, as `AtomicWrite.write`'s `beforeRename` does;
    /// a check that throws leaves the file as it was.
    public typealias Write =
        @Sendable (Data, URL, _ beforeRename: () throws -> Void) throws -> Void

    /// How long after a read that finds the file empty or gone the store reads it again before
    /// it believes it. An editor's save in place truncates then writes, and a sync tool may
    /// delete then create; both take a few milliseconds.
    public static let confirmDelay: Duration = .milliseconds(200)

    /// What the store tells its settings.
    public enum Update: Equatable, Sendable {
        /// A read of the file that differs from the last, with its generation.
        case read(ConfigLoad, generation: Int)
        /// Why the last write failed, or nil once one succeeds after a failure.
        case saved(failure: ConfigError?)
    }

    /// The file, as the user chose it: a symbolic link is followed to read and write it, and
    /// stays a link.
    public nonisolated let file: URL
    /// Each read after the first that differs from the one before, and each change in whether
    /// the writes fail, in order.
    public nonisolated let updates: AsyncStream<Update>
    private let feed: AsyncStream<Update>.Continuation
    /// Whether a write makes the file's folder when it isn't there: true for the default
    /// location, whose folder the app owns, and false for one the user chose, whose folder
    /// missing means its volume isn't connected.
    private let createsFolder: Bool
    private let reserved: Set<KeyChord>
    private let fixed: [KeyChord: CommandID]
    private let watch: Watch
    private let write: Write
    private let startWait: DeadlineWait.Start
    private let log: @Sendable (String) -> Void
    /// The second read of a file found empty or gone, waiting for `confirmDelay`; a change in
    /// the folder before it ends cancels it and reads the file at once.
    private var confirming: Task<Void, Never>?
    private var stopWatches: [@Sendable () -> Void] = []
    private var started = false
    /// The file as last read or written: its bytes, nil for no file, and what they load as.
    private var last: Read?
    private var generation = 0
    /// The sequence number of the last write, so a write that arrives after a later one is
    /// dropped.
    private var lastSequence = 0
    private var saveFailure: ConfigError?

    private struct Read: Equatable {
        let bytes: Data?
        let load: ConfigLoad
    }

    /// A store of `file`, watched through `watch`, written through `write`, and timing its
    /// second reads on `clock`. Each read checks the file's shortcuts against the menus'
    /// `reserved` and `fixed` chords (`ConfigLoad.checked(reserved:fixed:)`), which Browser
    /// can't see for itself. `log` gets each read's errors, each failed write and a watch that
    /// couldn't start.
    public init<C: Clock<Duration>>(
        file: URL, createsFolder: Bool, reserved: Set<KeyChord>, fixed: [KeyChord: CommandID],
        log: @escaping @Sendable (String) -> Void, watch: @escaping Watch = fileEvents,
        clock: C = ContinuousClock(),
        write: @escaping Write = { try AtomicWrite.write($0, to: $1, beforeRename: $2) }
    ) {
        self.file = file
        self.createsFolder = createsFolder
        self.reserved = reserved
        self.fixed = fixed
        self.log = log
        self.watch = watch
        self.write = write
        startWait = DeadlineWait.make(on: clock)
        (updates, feed) = AsyncStream.makeStream(of: Update.self)
    }

    /// Watches a folder through FSEvents.
    public static let fileEvents: Watch = { folder, onChange in
        let stream = try FileEventStream(path: folder) { _ in onChange() }
        return { stream.stop() }
    }

    /// The file a location the user chose names: `ConfigFile.name` in it when it is a folder,
    /// and itself otherwise. Call it off the main thread.
    public nonisolated static func file(forChosen url: URL) -> URL {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder),
            isFolder.boolValue
        else { return url }
        return url.appending(path: ConfigFile.name)
    }

    /// Whether there is a file at `url`, through any link at it. Call it off the main thread.
    public nonisolated static func fileIsThere(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Reads the file and starts watching its folder, and the folder of the file a link at
    /// its path leads to, and returns the read as generation 0; later reads go to `updates`.
    /// The watch starts after the read, so a change made between the two is read again.
    public func start() -> ConfigLoad {
        precondition(!started, "the config file is already watched")
        started = true
        let first = read()
        last = first
        for error in first.load.errors {
            log("the config file \(file.path) wasn't applied: \(error)")
        }
        var folders = [file.deletingLastPathComponent().path]
        let target = Self.target(of: file).deletingLastPathComponent().path
        if target != folders[0] { folders.append(target) }
        for folder in folders {
            do {
                stopWatches.append(
                    try watch(folder) { [weak self] in
                        guard let self else { return }
                        Task { await self.reload() }
                    })
            } catch {
                log("the config file's folder \(folder) isn't watched for changes: \(error)")
            }
        }
        reload()
        return first.load
    }

    /// Stops watching and ends `updates`.
    public func stop() {
        confirming?.cancel()
        confirming = nil
        for stop in stopWatches { stop() }
        stopWatches = []
        feed.finish()
    }

    /// Writes `contents` over the file, and returns whether the file now holds them. It
    /// doesn't when a read since generation `basedOn` changed what the file sets, which wins;
    /// or the file has an error, which a write would destroy; or the file is empty or gone and
    /// not yet confirmed so; or a write with a later `sequence` came first; or the write
    /// failed. The file is read once more first, so an edit whose change hasn't arrived yet is
    /// found and sent instead, and its bytes are compared again just before the rename, so an
    /// edit saved during the write is kept and sent; what is left is the few microseconds
    /// between that check and the rename, which no rename can close.
    @discardableResult
    public func save(_ contents: ConfigFile.Contents, basedOn: Int, sequence: Int) -> Bool {
        guard sequence > lastSequence, basedOn == generation else { return false }
        lastSequence = sequence
        let current = read()
        if isTransient(current) {
            confirm()
            return false
        }
        guard accept(current), let last, last.load.errors.isEmpty else { return false }
        let data = ConfigFile.data(contents)
        guard data != last.bytes else { return true }
        let target = Self.target(of: file)
        do {
            if createsFolder {
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try write(data, target) {
                if Self.bytes(at: target) != last.bytes { throw ChangedDuringWrite() }
            }
            self.last = Read(bytes: data, load: load(data))
            report(nil)
            return true
        } catch is ChangedDuringWrite {
            reload()
            return false
        } catch {
            report(
                ConfigError(
                    line: nil, key: nil,
                    reason: "couldn't be saved: \(error.localizedDescription)"))
            return false
        }
    }

    /// The file changed between the read a write was checked against and its rename.
    private struct ChangedDuringWrite: Error {}

    /// The bytes of the file at `url`; nil when it can't be read.
    private static func bytes(at url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    /// Makes the file from `contents`, the settings as of generation `basedOn`, when there is
    /// none, as Open Config File needs, and says whether there is a file to open. A deletion
    /// the settings haven't applied yet makes the file from the defaults, which they are about
    /// to read as. The write is create-only, so a file an editor saves meanwhile is kept and
    /// opened.
    public func makeIfMissing(_ contents: ConfigFile.Contents, basedOn: Int) -> Bool {
        let found = read()
        // A file just found gone isn't sent as a deletion here: the settings still have what
        // it held, which the file is made from.
        let transient = isTransient(found)
        let current = (transient || accept(found)) && basedOn == generation
        guard found.bytes == nil else { return true }
        guard found.load == .missing else { return false }
        let data = ConfigFile.data(
            current ? contents : ConfigFile.Contents(values: [:], shortcuts: [:]))
        do {
            if createsFolder {
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try AtomicWrite.create(data, at: Self.target(of: file))
            self.last = Read(bytes: data, load: load(data))
            report(nil)
        } catch POSIXError.EEXIST {
            // Made since the read, by the user: that file is the one to open.
        } catch {
            report(
                ConfigError(
                    line: nil, key: nil,
                    reason: "couldn't be created: \(error.localizedDescription)"))
            return false
        }
        return true
    }

    /// Reads the file again, and sends the read when it changes what the file sets. A read
    /// that finds it empty or gone waits for `confirm`; this read cancels one waiting.
    func reload() {
        confirming?.cancel()
        confirming = nil
        let read = read()
        if isTransient(read) {
            confirm()
        } else {
            _ = accept(read)
        }
    }

    /// Whether `read` finds the file empty or gone where the last read didn't: a state a save
    /// in place or a delete and create passes through, so it waits for a second read.
    private func isTransient(_ read: Read) -> Bool {
        let empty = read.bytes.map { $0.allSatisfy { [0x20, 0x09, 0x0A, 0x0D].contains($0) } }
        guard read.load == .missing || empty == true, let last else { return false }
        return read.load != last.load
    }

    /// Reads the file again `confirmDelay` from now, and sends what it finds then, unless a
    /// change in the folder reads it first.
    private func confirm() {
        guard confirming == nil else { return }
        let wait = startWait(Self.confirmDelay)
        confirming = Task {
            guard await DeadlineWait.reached(wait), !Task.isCancelled else { return }
            confirming = nil
            _ = accept(read())
        }
    }

    /// Takes `read` as the file's state, and sends it with the next generation when it loads
    /// differently from the last. Returns whether the load is the one the settings have.
    private func accept(_ read: Read) -> Bool {
        defer { last = read }
        guard let last, read.load != last.load else { return true }
        for error in read.load.errors {
            log("the config file \(file.path) wasn't applied: \(error)")
        }
        generation += 1
        feed.yield(.read(read.load, generation: generation))
        return false
    }

    /// Sends a change in whether the writes fail, and logs a failure.
    private func report(_ failure: ConfigError?) {
        guard failure != saveFailure else { return }
        saveFailure = failure
        if let failure { log("the config file \(file.path) \(failure)") }
        feed.yield(.saved(failure: failure))
    }

    /// The file's bytes and what they load as; `missing` when there is no file. A link to
    /// nothing, a folder that isn't there for a location the user chose, and a file that can't
    /// be read are errors with no line, which keep the file from being written.
    private func read() -> Read {
        func failed(_ reason: String) -> Read {
            Read(bytes: nil, load: .failed([ConfigError(line: nil, key: nil, reason: reason)]))
        }
        let files = FileManager.default
        do {
            let data = try Data(contentsOf: file)
            return Read(bytes: data, load: load(data))
        } catch CocoaError.fileReadNoSuchFile {
            // Reading follows a link, so a link to nothing reads as no file; written through,
            // it would become a file and stop being the link the user made.
            if let target = try? files.destinationOfSymbolicLink(atPath: file.path) {
                return failed("is a symbolic link to \(target), which doesn't exist")
            }
            let folder = file.deletingLastPathComponent().path
            if !createsFolder, !files.fileExists(atPath: folder) {
                return failed(
                    "is in \(folder), which isn't there: is its volume connected? Searcher keeps"
                        + " the settings it has")
            }
            return Read(bytes: nil, load: .missing)
        } catch {
            return failed("couldn't be read: \(error.localizedDescription)")
        }
    }

    private func load(_ data: Data) -> ConfigLoad {
        ConfigFile.parse(data).checked(reserved: reserved, fixed: fixed)
    }

    /// Where a write of `file` goes: the file a symbolic link at its path leads to, through
    /// any links after it, so the rename replaces that file and the link stays; `file` when it
    /// isn't a link.
    private static func target(of file: URL) -> URL {
        var url = file
        // A cycle of links is left at the last one, which the write then fails on.
        for _ in 0..<8 {
            guard
                let destination = try? FileManager.default.destinationOfSymbolicLink(
                    atPath: url.path)
            else { return url }
            // Not standardized, which would drop a leading /private the link names.
            url =
                destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : url.deletingLastPathComponent().appending(path: destination)
        }
        return url
    }
}
