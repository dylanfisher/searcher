import AppKit
import Browser
import os

/// Takes a drop's file promises, as Mail and Photos drag them: the queue makes a hidden folder in
/// the target folder, the source apps write their files into it, and the files that arrive move
/// into the target as one queued move, so a name already taken is asked about as for any move
/// and the moved files are selected as pasted ones are. The folder is then deleted with
/// anything left in it (docs/decisions/0071-drag-and-drop.md).
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

    private static let logger = Logger(category: "drop")

    /// Receives `promises` into `folder` through `queue`, and returns once the move has finished
    /// and the queue's folder is deleted. With a `pane`, the moved files are selected there.
    /// A file that fails to arrive is logged and left out; so is a failure to make or delete
    /// the folder.
    static func receive(
        _ promises: [any Promise], into folder: String, selectingIn pane: Pane?,
        queue: FileOperationQueue
    ) async {
        let staging: String
        do {
            staging = try await queue.makeDropFolder(in: folder)
        } catch {
            logger.error("no folder for promised files in \(folder, privacy: .public): \(error)")
            return
        }
        let (stream, feed) = AsyncStream.makeStream(of: (URL, (any Error)?).self)
        let stagingURL = URL(fileURLWithPath: staging, isDirectory: true)
        var promised = 0
        for promise in promises {
            promised += promise.receive(into: stagingURL) { url, error in
                feed.yield((url, error))
            }
        }
        var received: [String] = []
        var results = stream.makeAsyncIterator()
        while promised > 0, let (url, error) = await results.next() {
            promised -= 1
            if let error {
                logger.error("a promised file failed: \(url.path, privacy: .public): \(error)")
            } else {
                received.append(url.path)
            }
        }
        feed.finish()
        if !received.isEmpty {
            _ = await FileCommands.perform(
                .move(received, into: folder), selectingIn: pane, queue: queue)
        }
        do {
            try await queue.removeDropFolder(staging)
        } catch {
            logger.error("the drop folder \(staging, privacy: .public) is left: \(error)")
        }
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
