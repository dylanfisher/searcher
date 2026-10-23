import Darwin
import Foundation

/// Copies one item, a file, a symlink or a folder with everything in it, to a path that doesn't
/// exist yet. `copyfile(3)` does the copying: a clone on one APFS volume, and the metadata Finder
/// keeps on any. The creation date, which `copyfile` doesn't keep, is set on each entry after it.
/// A copy that fails or is cancelled removes what it wrote, so no partial item is left.
///
/// One copier serves one operation: `pause`, `resume` and `cancel` act on the copy running and on
/// every later one, from any thread. `copy` blocks its thread, which must be a
/// `BlockingCallThread`, for as long as the copy runs and while it is paused. See
/// docs/decisions/0058-copy-engine.md and docs/decisions/0062-file-copier.md.
public final class FileCopier: @unchecked Sendable {
    /// The shortest time between two progress reports.
    public static let progressInterval: Duration = .milliseconds(100)

    /// Time since the copier was made, on the clock it was given.
    fileprivate let elapsed: @Sendable () -> Duration
    // `condition` guards `isPaused` and `isCancelled`.
    private let condition = NSCondition()
    private var isPaused = false
    private var isCancelled = false

    public init<C: Clock<Duration>>(clock: C = ContinuousClock()) {
        let start = clock.now
        elapsed = { start.duration(to: clock.now) }
    }

    /// Stops the copy at its next block or entry, without giving up its thread, until `resume`.
    public func pause() {
        condition.withLock { isPaused = true }
    }

    public func resume() {
        condition.withLock {
            isPaused = false
            condition.broadcast()
        }
    }

    /// Stops the copy at its next block or entry, paused or not, and every later copy before it
    /// starts. Each throws `CancellationError`.
    public func cancel() {
        condition.withLock {
            isCancelled = true
            condition.broadcast()
        }
    }

    /// Waits while the copier is paused; returns false once it is cancelled.
    fileprivate func waitWhilePaused() -> Bool {
        condition.withLock {
            while isPaused, !isCancelled { condition.wait() }
            return !isCancelled
        }
    }

    /// Copies the item at `source` to `destination`, which must not exist. `progress` runs on the
    /// calling thread with each change, at most once per `progressInterval`; the first change is
    /// reported at once.
    ///
    /// - Returns: the bytes and files copied, which for a folder match `TreeSizeWalker`'s total.
    /// - Throws: `CancellationError` once `cancel` is called. `FileOperationError` for what the
    ///   system refused, with the path of the entry it refused: `exists` if `destination` does.
    ///   If what a stopped copy wrote can't be removed, the error is the removal's.
    public func copy(
        _ source: String, to destination: String, progress: (CopyProgress) -> Void = { _ in }
    ) throws -> CopyProgress {
        BlockingCallThread.requireCurrent()
        guard waitWhilePaused() else { throw CancellationError() }
        var info = stat()
        if lstat(source, &info) != 0 { throw FileOperationError(errno: errno, path: source) }
        let isFolder = info.st_mode & S_IFMT == S_IFDIR
        // A recursive copy onto an existing folder copies into it, so the name is checked first.
        if lstat(destination, &info) == 0 {
            throw FileOperationError(errno: EEXIST, path: destination)
        }
        return try withoutActuallyEscaping(progress) { progress in
            let run = CopyRun(copier: self, report: progress)
            do {
                try run.copy(source, to: destination, recursive: isFolder)
                return run.done
            } catch let error as FileOperationError
                where error.reason == .exists && error.path == destination
            {
                // Something else made `destination` after the check; this copy wrote nothing.
                throw error
            } catch {
                try Self.removePartialCopy(at: destination)
                throw error
            }
        }
    }

    /// Removes what a stopped copy left at `destination`. `copyfile` removes a file it stops
    /// copying, but leaves a folder's entries that it finished.
    private static func removePartialCopy(at destination: String) throws(FileOperationError) {
        var info = stat()
        if lstat(destination, &info) != 0 {
            if errno == ENOENT { return }
            throw FileOperationError(errno: errno, path: destination)
        }
        if removefile(destination, nil, removefile_flags_t(REMOVEFILE_RECURSIVE)) != 0 {
            throw FileOperationError(errno: errno, path: destination)
        }
    }
}

/// One call of `copyfile`: what it has copied, the last report, and why it stopped.
private final class CopyRun {
    private let copier: FileCopier
    private let report: (CopyProgress) -> Void
    /// Bytes of the regular files finished, and files and symlinks finished.
    private(set) var done = CopyProgress(bytes: 0, files: 0)
    private var lastReport: (progress: CopyProgress, at: Duration)?
    /// The first failure the callback saw; `copyfile` calls it again for the entry's parent step.
    private var failure: FileOperationError?
    private var wasCancelled = false

    init(copier: FileCopier, report: @escaping (CopyProgress) -> Void) {
        self.copier = copier
        self.report = report
    }

    func copy(_ source: String, to destination: String, recursive: Bool) throws {
        guard let state = copyfile_state_alloc() else {
            preconditionFailure("copyfile_state_alloc failed: errno \(errno)")
        }
        defer { copyfile_state_free(state) }
        let callback: copyfile_callback_t = { what, stage, state, source, destination, context in
            let code = errno
            guard let context, let state else { preconditionFailure("copyfile gave no state") }
            let run = Unmanaged<CopyRun>.fromOpaque(context).takeUnretainedValue()
            return run.status(
                what: what, stage: stage, state: state, code: code,
                source: source.map { String(cString: $0) },
                destination: destination.map { String(cString: $0) })
        }
        precondition(
            copyfile_state_set(
                state, UInt32(COPYFILE_STATE_STATUS_CB),
                unsafeBitCast(callback, to: UnsafeRawPointer.self)) == 0
                && copyfile_state_set(
                    state, UInt32(COPYFILE_STATE_STATUS_CTX),
                    Unmanaged.passUnretained(self).toOpaque()) == 0,
            "copyfile_state_set failed: errno \(errno)")
        // CLONE implies EXCL: a file is never written over. NOFOLLOW keeps symlinks as symlinks;
        // without it a recursive copy follows them and fails on a dangling one.
        var flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_NOFOLLOW)
        if recursive { flags |= copyfile_flags_t(COPYFILE_RECURSIVE) }
        let result = withExtendedLifetime(self) { copyfile(source, destination, state, flags) }
        let code = errno
        if let failure { throw failure }
        if wasCancelled { throw CancellationError() }
        guard result == 0 else {
            // A copy that failed before its first callback, such as on an unreadable file.
            throw FileOperationError(
                errno: code, path: Self.failedPath(code, source: source, destination: destination))
        }
        // A recursive copy finishes each entry in the callback; a single one is finished here.
        if !recursive { try finishEntry(source, copiedTo: destination) }
    }

    /// Handles one call of `copyfile`'s status callback, made after each block of data and at
    /// the start and end of each entry.
    private func status(
        what: Int32, stage: Int32, state: copyfile_state_t, code: Int32, source: String?,
        destination: String?
    ) -> Int32 {
        if stage == COPYFILE_ERR {
            // A copy stopped for cancel reports ECANCELED here.
            if failure == nil, !wasCancelled, let source, let destination {
                failure = FileOperationError(
                    errno: code,
                    path: Self.failedPath(code, source: source, destination: destination))
            }
            return Int32(COPYFILE_QUIT)
        }
        switch (what, stage) {
        case (Int32(COPYFILE_COPY_DATA), Int32(COPYFILE_PROGRESS)):
            var copied: off_t = 0
            copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
            note(CopyProgress(bytes: done.bytes + copied, files: done.files))
        case (Int32(COPYFILE_RECURSE_FILE), Int32(COPYFILE_FINISH)),
            (Int32(COPYFILE_RECURSE_DIR_CLEANUP), Int32(COPYFILE_FINISH)):
            guard let source, let destination else {
                preconditionFailure("copyfile finished an entry without its paths")
            }
            do {
                try finishEntry(source, copiedTo: destination)
            } catch {
                failure = error
                return Int32(COPYFILE_QUIT)
            }
            note(done)
        default:
            break
        }
        if copier.waitWhilePaused() { return Int32(COPYFILE_CONTINUE) }
        wasCancelled = true
        return Int32(COPYFILE_QUIT)
    }

    /// Reports `progress` if it changed and the last report is at least `progressInterval` old.
    private func note(_ progress: CopyProgress) {
        let now = copier.elapsed()
        if let lastReport {
            guard progress != lastReport.progress,
                now - lastReport.at >= FileCopier.progressInterval
            else { return }
        }
        lastReport = (progress, now)
        report(progress)
    }

    /// Sets the creation date of the copy of `source` and counts it, once `copyfile` has
    /// finished it. A folder is finished after its entries, so writing them can't change it.
    private func finishEntry(_ source: String, copiedTo destination: String)
        throws(FileOperationError)
    {
        var info = stat()
        if lstat(source, &info) != 0 { throw FileOperationError(errno: errno, path: source) }
        try Self.setCreationDate(info.st_birthtimespec, of: destination)
        switch info.st_mode & S_IFMT {
        case S_IFDIR: break
        case S_IFREG: done = CopyProgress(bytes: done.bytes + info.st_size, files: done.files + 1)
        default: done = CopyProgress(bytes: done.bytes, files: done.files + 1)
        }
    }

    private static func setCreationDate(_ date: timespec, of path: String)
        throws(FileOperationError)
    {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var date = date
        let options = UInt32(FSOPT_NOFOLLOW)
        if setattrlist(path, &request, &date, MemoryLayout<timespec>.size, options) == 0 { return }
        let code = errno
        // A locked copy refuses every change, so it is unlocked for the one call.
        var info = stat()
        guard code == EPERM, lstat(path, &info) == 0, info.st_flags & UInt32(UF_IMMUTABLE) != 0
        else { throw FileOperationError(errno: code, path: path) }
        if lchflags(path, info.st_flags & ~UInt32(UF_IMMUTABLE)) != 0
            || setattrlist(path, &request, &date, MemoryLayout<timespec>.size, options) != 0
            || lchflags(path, info.st_flags) != 0
        {
            throw FileOperationError(errno: errno, path: path)
        }
    }

    /// The path a failure with `code` is about. A full volume or an existing name is about the
    /// destination; denied access is about the source unless the source can be read.
    static func failedPath(_ code: Int32, source: String, destination: String) -> String {
        switch code {
        case ENOSPC, EDQUOT, EEXIST: destination
        case EACCES, EPERM:
            faccessat(AT_FDCWD, source, R_OK, AT_SYMLINK_NOFOLLOW) == 0 ? destination : source
        default: source
        }
    }
}
