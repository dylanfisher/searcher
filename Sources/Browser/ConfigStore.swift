import Base
import Foundation

/// Reads the config file, reads it again after each change in its folder, and writes each
/// change made in the app into it, all off the main actor
/// (docs/decisions/0123-config-is-the-settings.md). It watches the folder rather than the file,
/// since an editor's atomic save, and Dropbox's, replaces the file; and the folder may not exist
/// yet: FSEvents matches the path of each change, so changes arrive once the folder is made.
///
/// A change made in the app comes as a `ConfigPatch`, and is written by reading the file,
/// setting that one key in it and writing it back, so an edit of any other key is kept. The
/// patches wait in a queue, the latest of each key only, while the file has an error, is
/// empty or gone and not yet confirmed so, or can't be written; each read sent to the settings
/// has them on top. A read is compared with the file as last read or written, byte for byte, so
/// the store's own write, a save that changes nothing and another file changing in the folder
/// send nothing. A read that finds the file empty or gone is believed only once a second read
/// `confirmDelay` later still finds it so, since an editor's save in place and a sync tool's
/// delete and create pass through both.
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

    /// What the store tells its settings.
    public enum Update: Equatable, Sendable {
        /// A read of the file that differs from the last, with the patches not yet written
        /// on top of it.
        case read(ConfigLoad)
        /// Every patch up to this sequence number is in the file.
        case wrote(through: Int)
        /// Why the last write failed, or nil once one succeeds after a failure.
        case saved(failure: ConfigError?)
    }

    /// How long after a read that finds the file empty or gone the store reads it again before
    /// it believes it. An editor's save in place truncates then writes, and a sync tool may
    /// delete then create; both take a few milliseconds.
    public static let confirmDelay: Duration = .milliseconds(200)
    /// The wait before the first retry of a write that failed; each retry after one that
    /// fails waits twice as long, up to `longestRetryDelay`.
    public static let firstRetryDelay: Duration = .seconds(1)
    public static let longestRetryDelay: Duration = .seconds(30)
    /// How many times a write starts over because the file changed during it before it waits
    /// for a retry.
    static let attempts = 5

    /// The file, as the user chose it: a symbolic link is followed to read and write it, and
    /// stays a link.
    public nonisolated let file: URL
    /// Each read after the first that differs from the one before, each write of patches, and
    /// each change in whether the writes fail, in order.
    public nonisolated let updates: AsyncStream<Update>
    private let feed: AsyncStream<Update>.Continuation
    /// The patches `send` hands over, in order, which the store takes once it has started.
    private let inbox: AsyncStream<(ConfigPatch, Int)>
    private let inboxFeed: AsyncStream<(ConfigPatch, Int)>.Continuation
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
    private var stopWatches: [@Sendable () -> Void] = []
    private var started = false
    private var stopped = false
    /// The file as last read or written: its bytes, nil for no file, and what they load as.
    private var last: Read?
    /// The patches not yet written, the latest of each key, each with its sequence number.
    private var queue: [ConfigPatch.Target: (patch: ConfigPatch, sequence: Int)] = [:]
    /// The highest sequence number taken from the inbox, and the highest written.
    private var received = 0
    private var written = 0
    /// Those waiting for `waitUntilWritten`, each with the sequence number it waits for.
    private var waiters: [(sequence: Int, continuation: CheckedContinuation<Void, Never>)] = []
    /// The second read of a file found empty or gone, waiting for `confirmDelay`; a change in
    /// the folder before it ends cancels it and reads the file at once.
    private var confirming: Task<Void, Never>?
    /// The wait before a failed write is tried again, and how long the next one waits.
    private var retrying: Task<Void, Never>?
    private var retryDelay: Duration?
    private var saveFailure: ConfigError?

    private struct Read: Equatable {
        let bytes: Data?
        let load: ConfigLoad
    }

    /// A store of `file`, watched through `watch`, written through `write`, and timing its
    /// second reads and retries on `clock`. Each read checks the file's shortcuts against the
    /// menus' `reserved` and `fixed` chords (`ConfigLoad.checked(reserved:fixed:)`), which
    /// Browser can't see for itself. `log` gets each read's errors, each failed write and a
    /// watch that couldn't start.
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
        (inbox, inboxFeed) = AsyncStream.makeStream(of: (ConfigPatch, Int).self)
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

    /// Hands `patch`, the app's change number `sequence`, to the store to write. Patches are
    /// taken in the order they are sent, and wait until `start` has read the file.
    nonisolated func send(_ patch: ConfigPatch, sequence: Int) {
        inboxFeed.yield((patch, sequence))
    }

    /// Reads the file, writes `contents` there when there is none, starts watching its folder
    /// and the folder of the file a link at its path leads to, and returns the read; later
    /// reads go to `updates`. Then takes the patches sent, those sent before it among them.
    /// The watch starts after the read, so a change made between the two is read again.
    public func start(writingIfMissing contents: ConfigFile.Contents) -> ConfigLoad {
        precondition(!started, "the config file is already watched")
        started = true
        var first = read()
        for error in first.load.errors {
            log("the config file \(file.path) wasn't applied: \(error)")
        }
        last = first
        if first.load == .missing {
            first = writeNew(ConfigFile.data(contents)) ?? first
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
        let inbox = inbox
        Task { [weak self] in
            for await (patch, sequence) in inbox {
                guard let self else { return }
                await receive(patch, sequence: sequence)
            }
        }
        reload()
        return first.load
    }

    /// Stops watching, ends `updates`, and lets go of anyone waiting for a write.
    public func stop() {
        stopped = true
        confirming?.cancel()
        confirming = nil
        retrying?.cancel()
        retrying = nil
        for stop in stopWatches { stop() }
        stopWatches = []
        inboxFeed.finish()
        feed.finish()
        for waiter in waiters { waiter.continuation.resume() }
        waiters = []
    }

    /// Returns once every patch up to `sequence` is in the file, or the store has stopped.
    public func waitUntilWritten(through sequence: Int) async {
        guard written < sequence, !stopped else { return }
        await withCheckedContinuation { waiters.append((sequence, $0)) }
    }

    /// Makes the file from `contents`, the settings as they are, when there is none, as Open
    /// Config File needs, and says whether there is a file to open. The write is create-only,
    /// so a file an editor saves meanwhile is kept and opened.
    public func makeIfMissing(_ contents: ConfigFile.Contents) -> Bool {
        let found = read()
        guard found.bytes == nil else { return true }
        guard found.load == .missing else { return false }
        let data = ConfigFile.data(contents)
        do {
            if createsFolder {
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try AtomicWrite.create(data, at: Self.target(of: file))
            last = Read(bytes: data, load: load(data))
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
        drain()
        return true
    }

    /// Reads the file again, sends the read when it changes what the file sets, and writes the
    /// patches waiting. A read that finds it empty or gone waits for `confirm`; this read
    /// cancels one waiting.
    func reload() {
        confirming?.cancel()
        confirming = nil
        let read = read()
        if isTransient(read) {
            confirm()
            return
        }
        accept(read)
        drain()
    }

    /// Takes the patch the app sent as change `sequence`, replacing one of the same key still
    /// waiting, and writes it.
    func receive(_ patch: ConfigPatch, sequence: Int) {
        queue[patch.target] = (patch, sequence)
        received = max(received, sequence)
        drain()
    }

    /// Writes the patches waiting into the file as it is now, unless it has an error, is empty
    /// or gone and not yet confirmed so, or a retry is waiting. Each attempt reads the file,
    /// sets the patches' keys in it and writes it back; just before the rename the file's
    /// bytes are compared with that read, and on a difference the attempt starts over. What
    /// is left is the few microseconds between that check and the rename, which no rename can
    /// close.
    private func drain() {
        guard started, !queue.isEmpty, confirming == nil, retrying == nil else { return }
        for _ in 0..<Self.attempts {
            let current = read()
            if isTransient(current) {
                confirm()
                return
            }
            accept(current)
            guard let base = object(of: current) else { return }
            let patches = queue.values.map(\.patch).filter { !$0.isSatisfied(by: current.load) }
            if patches.isEmpty {
                wrote()
                return
            }
            var object = base
            for patch in patches { patch.apply(to: &object) }
            let data = ConfigFile.data(object: object)
            let target = Self.target(of: file)
            do {
                if createsFolder {
                    try FileManager.default.createDirectory(
                        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                }
                try write(data, target) {
                    if Self.bytes(at: target) != current.bytes { throw ChangedDuringWrite() }
                }
                last = Read(bytes: data, load: load(data))
                retryDelay = nil
                report(nil)
                wrote()
                return
            } catch is ChangedDuringWrite {
                continue
            } catch {
                report(
                    ConfigError(
                        line: nil, key: nil,
                        reason: "couldn't be saved: \(error.localizedDescription)"))
                retry()
                return
            }
        }
        retry()
    }

    /// The file changed between the read a write was checked against and its rename.
    private struct ChangedDuringWrite: Error {}

    /// The JSON object the patches go into: the file's, or for no file every default; nil
    /// while the file has an error, which a write would destroy.
    private func object(of read: Read) -> [String: Any]? {
        if read.load == .missing {
            return ConfigFile.object(ConfigFile.Contents(values: [:], shortcuts: [:]))
        }
        guard read.load.errors.isEmpty, let bytes = read.bytes else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }

    /// Writes `data` as the file where there is none, and returns the read it makes; nil, with
    /// the failure reported, when it can't.
    private func writeNew(_ data: Data) -> Read? {
        let target = Self.target(of: file)
        do {
            if createsFolder {
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try write(data, target) {
                if Self.bytes(at: target) != nil { throw ChangedDuringWrite() }
            }
            let written = Read(bytes: data, load: load(data))
            last = written
            report(nil)
            return written
        } catch is ChangedDuringWrite {
            // Made meanwhile, by the user: the watch reads it.
            return nil
        } catch {
            report(
                ConfigError(
                    line: nil, key: nil,
                    reason: "couldn't be saved: \(error.localizedDescription)"))
            return nil
        }
    }

    /// Marks every patch waiting as written, tells the settings, and lets go of those waiting
    /// for it.
    private func wrote() {
        queue = [:]
        written = received
        feed.yield(.wrote(through: written))
        let done = waiters.filter { $0.sequence <= written }
        waiters.removeAll { $0.sequence <= written }
        for waiter in done { waiter.continuation.resume() }
    }

    /// Tries the write again after a wait that doubles from `firstRetryDelay` with each
    /// failure, up to `longestRetryDelay`.
    private func retry() {
        let delay = min(
            retryDelay.map { $0 * 2 } ?? Self.firstRetryDelay, Self.longestRetryDelay)
        retryDelay = delay
        let wait = startWait(delay)
        retrying = Task {
            guard await DeadlineWait.reached(wait), !Task.isCancelled else { return }
            retrying = nil
            drain()
        }
    }

    /// The bytes of the file at `url`; nil when it can't be read.
    private static func bytes(at url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    /// Whether `read` finds the file empty or gone where the last read didn't: a state a save
    /// in place or a delete and create passes through, so it waits for a second read.
    private func isTransient(_ read: Read) -> Bool {
        let empty = read.bytes.map { $0.allSatisfy { [0x20, 0x09, 0x0A, 0x0D].contains($0) } }
        guard read.load == .missing || empty == true, let last else { return false }
        return read.load != last.load
    }

    /// Reads the file again `confirmDelay` from now, takes what it finds then and writes the
    /// patches waiting, unless a change in the folder reads it first.
    private func confirm() {
        guard confirming == nil else { return }
        let wait = startWait(Self.confirmDelay)
        confirming = Task {
            guard await DeadlineWait.reached(wait), !Task.isCancelled else { return }
            confirming = nil
            accept(read())
            drain()
        }
    }

    /// Takes `read` as the file's state, and sends it, with the patches waiting on top, when
    /// it loads differently from the last.
    private func accept(_ read: Read) {
        defer { last = read }
        guard let last, read.load != last.load else { return }
        for error in read.load.errors {
            log("the config file \(file.path) wasn't applied: \(error)")
        }
        feed.yield(.read(withPatches(read.load)))
    }

    /// `load` with the patches waiting set in it; a load with an error as it is.
    private func withPatches(_ load: ConfigLoad) -> ConfigLoad {
        guard load.errors.isEmpty, !queue.isEmpty else { return load }
        var contents = ConfigFile.Contents(values: load.values, shortcuts: load.shortcuts)
        for (patch, _) in queue.values { patch.apply(to: &contents) }
        return ConfigLoad(outcome: .values(contents.values, shortcuts: contents.shortcuts))
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
