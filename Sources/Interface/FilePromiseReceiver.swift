import AppKit
import Base
import Browser
import os

/// Takes a drop's file promises, as Mail and Photos drag them: the queue makes a hidden folder in
/// the target folder, the source apps write their files into it, and the files that arrive move
/// into the target as one queued move, so a name already taken is asked about as for any move
/// and the moved files are selected as pasted ones are. The queue then removes the folder,
/// trashing anything left in it. What fails, a file that didn't arrive, a source that stopped
/// writing for `idleTimeout`, or a folder that couldn't be made or removed, shows as one failed
/// row in the operations panel and is logged (docs/decisions/0071-drag-and-drop.md). So does a
/// folder that can't be read while the files are on their way.
@MainActor
enum FilePromiseReceiver {
    /// One promised item of a drop. `NSFilePromiseReceiver` outside tests.
    protocol Promise: AnyObject {
        /// Asks the source to write the promised files into `folder` and returns how many it
        /// promised. `reader` gets each file's URL, or an error for one that failed, on no
        /// particular thread.
        func receive(into folder: URL, reader: @escaping @Sendable (URL, (any Error)?) -> Void)
            -> Int
    }

    /// How long a drop waits with no new bytes in its folder and no file arriving before it
    /// gives up on the files still promised. A large file still being written keeps it waiting.
    nonisolated static let idleTimeout: Duration = .seconds(60)
    /// How often a drop reads how many bytes its folder holds, to tell a source still writing
    /// from one that stopped.
    nonisolated static let progressInterval: Duration = .seconds(5)

    private static let logger = Logger(category: "drop")

    /// What the receiver waits for: a file, `idleTimeout` with nothing new, or a folder that
    /// can't be read.
    private enum Event: Sendable {
        case file(URL, (any Error)?)
        case idle
        case unreadable(FileOperationError)
    }

    /// How long the drop has gone with nothing new, which a file's arrival resets.
    private final class Idle {
        var time: Duration = .zero
    }

    /// Receives `promises` into `folder` through `queue`, and returns once the move has finished
    /// and the queue's folder is removed. With a `pane`, the moved files are selected there.
    /// `app` names the app the drop came from, for a failure's row. `clock` times the reads of
    /// the folder's size and the wait with nothing new.
    static func receive(
        _ promises: [any Promise], into folder: String, from app: String?,
        selectingIn pane: Pane?, queue: FileOperationQueue,
        clock: any Clock<Duration> = ContinuousClock()
    ) async {
        var errors: [FileOperationError] = []
        var failedNames: [String] = []
        let dropFolder: FileOperationQueue.DropFolder
        do {
            dropFolder = try await queue.makeDropFolder(in: folder)
        } catch {
            await report(
                [error], names: [], app: app, folder: folder, queue: queue)
            return
        }
        let (stream, feed) = AsyncStream.makeStream(of: Event.self)
        let dropURL = URL(fileURLWithPath: dropFolder.path, isDirectory: true)
        var promised = 0
        for promise in promises {
            promised += promise.receive(into: dropURL) { url, error in
                feed.yield(.file(url, error))
            }
        }
        let idle = Idle()
        let watch = watchProgress(
            of: dropFolder, queue: queue, idle: idle, clock: clock, feed: feed)
        var received: [String] = []
        var events = stream.makeAsyncIterator()
        while promised > 0, let event = await events.next() {
            switch event {
            case .file(let url, let error):
                promised -= 1
                idle.time = .zero
                let name = url.lastPathComponent
                if let error {
                    failedNames.append(name)
                    errors.append(Self.error(error, path: join(folder, name)))
                } else if let path = await queue.resolved(url.path, in: dropFolder) {
                    received.append(path)
                } else {
                    // Only what the source wrote into the drop folder moves into the target.
                    logger.error(
                        "a drop's source reported \(url.path) outside \(dropFolder.path); left there"
                    )
                    failedNames.append(name)
                    errors.append(
                        FileOperationError(reason: .other, path: join(folder, name), errno: nil))
                }
            case .idle:
                promised = 0
                // The folder the source stopped writing to; the row names the app.
                errors.append(
                    FileOperationError(
                        reason: .unreachable, path: dropFolder.path, errno: ETIMEDOUT))
            case .unreadable(let error):
                promised = 0
                errors.append(error)
            }
        }
        watch.cancel()
        feed.finish()
        if !received.isEmpty {
            _ = await FileCommands.perform(
                .move(received, into: folder), selectingIn: pane, queue: queue)
        }
        errors += await queue.removeDropFolder(dropFolder)
        if !errors.isEmpty {
            await report(errors, names: failedNames, app: app, folder: folder, queue: queue)
        }
    }

    /// Reads the bytes in `dropFolder` every `progressInterval`, off the main thread, and sends
    /// `.idle` once `idleTimeout` has passed with no more bytes and no file arriving, or
    /// `.unreadable` once the folder can't be read.
    private static func watchProgress(
        of dropFolder: FileOperationQueue.DropFolder, queue: FileOperationQueue, idle: Idle,
        clock: any Clock<Duration>, feed: AsyncStream<Event>.Continuation
    ) -> Task<Void, Never> {
        Task {
            var bytes: Int64 = 0
            while true {
                guard await DeadlineWait.reached({ try await clock.sleep(for: progressInterval) })
                else { return }
                let now: Int64
                do throws(FileOperationError) {
                    now = try await queue.bytes(in: dropFolder)
                } catch {
                    feed.yield(.unreadable(error))
                    return
                }
                if now > bytes {
                    bytes = now
                    idle.time = .zero
                } else {
                    idle.time += progressInterval
                }
                if idle.time >= idleTimeout {
                    feed.yield(.idle)
                    return
                }
            }
        }
    }

    /// Logs `errors` and shows them as one failed row, named after the file when one file
    /// failed, else after the app.
    private static func report(
        _ errors: [FileOperationError], names: [String], app: String?, folder: String,
        queue: FileOperationQueue
    ) async {
        for error in errors {
            let text = String(describing: error)
            logger.error(
                "a drop into \(folder) failed: \(text)")
        }
        let name = names.count == 1 && errors.count == 1 ? names[0] : nil
        await queue.report(.receive(name: name, app: app, into: folder), errors: errors)
    }

    /// `error`, from a source app writing a promised file to `path`, as the panel shows it.
    private static func error(_ error: any Error, path: String) -> FileOperationError {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain {
            return FileOperationError(errno: Int32(error.code), path: path)
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
            underlying.domain == NSPOSIXErrorDomain
        {
            return FileOperationError(errno: Int32(underlying.code), path: path)
        }
        return FileOperationError(reason: .other, path: path, errno: nil)
    }
}

extension NSFilePromiseReceiver: FilePromiseReceiver.Promise {
    /// Calls in the promises with the reader on a queue of its own, off the main thread, since
    /// it waits on the source's write. The receiver lists the file names only once called in.
    func receive(
        into folder: URL, reader: @escaping @Sendable (URL, (any Error)?) -> Void
    ) -> Int {
        receivePromisedFiles(
            atDestination: folder, options: [:], operationQueue: OperationQueue(),
            reader: reader)
        return fileNames.count
    }
}
