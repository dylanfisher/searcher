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
/// row in the operations panel and is logged (docs/decisions/0071-drag-and-drop.md).
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

    /// How long a drop waits for the next promised file before it gives up on the rest.
    static let idleTimeout: Duration = .seconds(60)

    private static let logger = Logger(category: "drop")

    /// What the receiver waits for: a file, or the end of a wait for one.
    private enum Event: Sendable {
        case file(URL, (any Error)?)
        case idle(wait: Int)
    }

    /// Receives `promises` into `folder` through `queue`, and returns once the move has finished
    /// and the queue's folder is removed. With a `pane`, the moved files are selected there.
    /// `app` names the app the drop came from, for a failure's row. `clock` times the wait for
    /// each file.
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
        var wait = 0
        var timer = startWait(wait, clock: clock, feed: feed)
        var received: [String] = []
        var events = stream.makeAsyncIterator()
        while promised > 0, let event = await events.next() {
            switch event {
            case .file(let url, let error):
                promised -= 1
                wait += 1
                timer.cancel()
                timer = startWait(wait, clock: clock, feed: feed)
                if let error {
                    let name = url.lastPathComponent
                    failedNames.append(name)
                    errors.append(Self.error(error, path: folder + "/" + name))
                } else {
                    received.append(url.path)
                }
            case .idle(let ended) where ended == wait:
                promised = 0
                errors.append(
                    FileOperationError(
                        reason: .unreachable, path: app ?? "The app the files came from",
                        errno: ETIMEDOUT))
            case .idle:
                continue
            }
        }
        timer.cancel()
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

    /// Starts a wait of `idleTimeout` that ends with `.idle(wait:)` unless cancelled first.
    private static func startWait(
        _ wait: Int, clock: any Clock<Duration>, feed: AsyncStream<Event>.Continuation
    ) -> Task<Void, Never> {
        Task {
            do {
                try await clock.sleep(for: idleTimeout)
            } catch is CancellationError {
                return
            } catch {
                preconditionFailure("the clock failed a wait with \(error)")
            }
            feed.yield(.idle(wait: wait))
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
                "a drop into \(folder, privacy: .public) failed: \(text, privacy: .public)")
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
