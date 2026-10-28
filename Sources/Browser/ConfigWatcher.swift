import Base
import Foundation

/// Reads the config file, and reads it again after each change in its folder, off the main
/// actor. It watches the folder rather than the file, since an editor's atomic save replaces the
/// file, and the folder may not exist yet: FSEvents matches the path of each change, so changes
/// arrive once the folder is made (docs/decisions/0120-config-format.md).
public actor ConfigWatcher {
    /// Starts watching `folder`, calling `onChange` after each batch of changes in it, and
    /// returns what stops the watch.
    public typealias Watch =
        @Sendable (_ folder: String, _ onChange: @escaping @Sendable () -> Void) throws
        -> @Sendable () -> Void

    /// Each read after the first that differs from the one before, in order.
    public nonisolated let loads: AsyncStream<ConfigLoad>
    private let feed: AsyncStream<ConfigLoad>.Continuation
    private let file: URL
    private let watch: Watch
    private let log: @Sendable (String) -> Void
    private var stopWatch: (@Sendable () -> Void)?
    private var last: ConfigLoad?

    /// A watcher of `file`, through `watch`. `log` gets each read's errors and a watch that
    /// couldn't start.
    public init(
        file: URL, log: @escaping @Sendable (String) -> Void, watch: @escaping Watch = fileEvents
    ) {
        self.file = file
        self.log = log
        self.watch = watch
        (loads, feed) = AsyncStream.makeStream(of: ConfigLoad.self)
    }

    /// Watches the file's folder through FSEvents.
    public static let fileEvents: Watch = { folder, onChange in
        let stream = try FileEventStream(path: folder) { _ in onChange() }
        return { stream.stop() }
    }

    /// Reads the file and starts watching its folder, and returns the read; later reads go to
    /// `loads`. The watch starts after the read, so a change made between the two is read again.
    public func start() -> ConfigLoad {
        precondition(stopWatch == nil, "the config file is already watched")
        let first = read()
        last = first
        do {
            stopWatch = try watch(file.deletingLastPathComponent().path) { [weak self] in
                guard let self else { return }
                Task { await self.reload() }
            }
        } catch {
            log("the config file \(file.path) isn't watched for changes: \(error)")
        }
        reload()
        return first
    }

    /// Stops watching and ends `loads`.
    public func stop() {
        stopWatch?()
        stopWatch = nil
        feed.finish()
    }

    /// Sends `errors`, found with the file outside a read, as Open Config File finds a file it
    /// can't make, and logs them. They count as the last read, so the next read, which differs
    /// from them, is sent and clears them.
    public func report(_ errors: [ConfigError]) {
        let load = ConfigLoad.failed(errors)
        for error in errors {
            log("the config file \(file.path) has a problem: \(error)")
        }
        last = load
        feed.yield(load)
    }

    /// Reads the file again, and sends the read when it differs from the last.
    func reload() {
        let load = read()
        guard load != last else { return }
        last = load
        feed.yield(load)
    }

    /// The file's values or errors, logging the errors; `missing` when there is no file.
    private func read() -> ConfigLoad {
        let load: ConfigLoad
        do {
            let data = try Data(contentsOf: file)
            if let text = String(data: data, encoding: .utf8) {
                load = ConfigParser.parse(text)
            } else {
                load = .failed([ConfigError(line: nil, key: nil, reason: "isn't UTF-8 text")])
            }
        } catch CocoaError.fileReadNoSuchFile {
            return .missing
        } catch {
            load = .failed([
                ConfigError(
                    line: nil, key: nil, reason: "couldn't be read: \(error.localizedDescription)")
            ])
        }
        for error in load.errors where load != last {
            log("the config file \(file.path) wasn't applied: \(error)")
        }
        return load
    }
}
