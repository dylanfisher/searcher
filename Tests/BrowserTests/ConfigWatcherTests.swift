import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser

/// A watch that reports a change only when the test says so.
private final class ManualWatch: Sendable {
    private let changes = OSAllocatedUnfairLockBox<(@Sendable () -> Void)?>(nil)
    let folders = EventLog<String>()
    let stops = EventLog<Void>()

    var watch: ConfigWatcher.Watch {
        { folder, onChange in
            self.folders.append(folder)
            self.changes.set(onChange)
            return { self.stops.append(()) }
        }
    }

    /// Reports a change in the watched folder, as an event batch from FSEvents does.
    func change() {
        guard let onChange = changes.get() else {
            Issue.record("nothing is watched")
            return
        }
        onChange()
    }
}

/// A value behind a lock.
private final class OSAllocatedUnfairLockBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}

/// The next load the watcher sends, or nil when the test waited `patience` for it.
private func nextLoad(_ loads: AsyncStream<ConfigLoad>) async -> ConfigLoad? {
    await bounded(
        Task {
            var iterator = loads.makeAsyncIterator()
            return await iterator.next()
        })
        ?? nil
}

@Test func startingWithNoFileLoadsNothing() async throws {
    let folder = try TemporaryFolder("ConfigWatcherTests")
    let watch = ManualWatch()
    let watcher = ConfigWatcher(
        file: folder.url.appending(path: "searcher/config"), log: { _ in }, watch: watch.watch)

    #expect(await watcher.start() == .missing)
    #expect(watch.folders.all == [folder.url.appending(path: "searcher").path])
}

@Test func startingReadsTheFile() async throws {
    let folder = try TemporaryFolder("ConfigWatcherTests")
    let file = folder.url.appending(path: "config")
    try Data("show-hidden = true".utf8).write(to: file)
    let watcher = ConfigWatcher(file: file, log: { _ in }, watch: ManualWatch().watch)

    #expect(await watcher.start() == ConfigParser.parse("show-hidden = true"))
}

/// An edit on disk, a replacement by an editor's atomic save and a deletion each send the load
/// that follows from the file after them. A change that leaves the load as it was sends none.
@Test func eachChangeOnDiskSendsTheNewLoad() async throws {
    let folder = try TemporaryFolder("ConfigWatcherTests")
    let file = folder.url.appending(path: "config")
    try Data("show-hidden = true".utf8).write(to: file)
    let watch = ManualWatch()
    let watcher = ConfigWatcher(file: file, log: { _ in }, watch: watch.watch)
    _ = await watcher.start()

    // Atomic, so a read the first change starts can't find the file half written.
    try Data("show-hidden = true # same".utf8).write(to: file, options: .atomic)
    watch.change()
    try Data("folders-first = true".utf8).write(to: file, options: .atomic)
    watch.change()
    #expect(await nextLoad(watcher.loads) == ConfigParser.parse("folders-first = true"))

    let saved = folder.url.appending(path: "config.tmp")
    try Data("folders-first = false".utf8).write(to: saved)
    _ = try FileManager.default.replaceItemAt(file, withItemAt: saved)
    watch.change()
    #expect(await nextLoad(watcher.loads) == ConfigParser.parse("folders-first = false"))

    try FileManager.default.removeItem(at: file)
    watch.change()
    #expect(await nextLoad(watcher.loads) == .missing)
}

/// Each error is logged once with its line, and again only after a load without it.
@Test func errorsAreLoggedOncePerLoad() async throws {
    let folder = try TemporaryFolder("ConfigWatcherTests")
    let file = folder.url.appending(path: "config")
    try Data("show-hidden = maybe".utf8).write(to: file)
    let logged = EventLog<String>()
    let watch = ManualWatch()
    let watcher = ConfigWatcher(file: file, log: { logged.append($0) }, watch: watch.watch)

    let load = await watcher.start()
    watch.change()
    try Data("folders-first = true".utf8).write(to: file, options: .atomic)
    watch.change()
    _ = await nextLoad(watcher.loads)

    #expect(load.errors.map(\.line) == [1])
    #expect(logged.all.count == 1)
    #expect(logged.all.first?.contains("line 1") == true)
    #expect(logged.all.first?.contains(file.path) == true)
}

@Test func aFileThatIsntUTF8IsAnError() async throws {
    let folder = try TemporaryFolder("ConfigWatcherTests")
    let file = folder.url.appending(path: "config")
    try Data([0xFF, 0xFE, 0x00]).write(to: file)
    let watcher = ConfigWatcher(file: file, log: { _ in }, watch: ManualWatch().watch)

    let errors = await watcher.start().errors

    #expect(errors.count == 1)
    #expect(errors.first?.line == nil)
}

@Test func stoppingStopsTheWatch() async throws {
    let folder = try TemporaryFolder("ConfigWatcherTests")
    let watch = ManualWatch()
    let watcher = ConfigWatcher(
        file: folder.url.appending(path: "config"), log: { _ in }, watch: watch.watch)
    _ = await watcher.start()

    await watcher.stop()

    #expect(watch.stops.all.count == 1)
}

/// The settings take the first load before `follow` returns, so the windows open with it, and
/// each later one as it comes.
@MainActor @Test func settingsFollowTheWatchersLoads() async throws {
    let folder = try TemporaryFolder("ConfigWatcherTests")
    let file = folder.url.appending(path: "config")
    try Data("show-hidden = true".utf8).write(to: file)
    let watch = ManualWatch()
    let settings = untouchedSettings()

    let watcher = ConfigWatcher(file: file, log: { _ in }, watch: watch.watch)

    await settings.follow(watcher)
    #expect(settings.showHidden)

    try Data("show-hidden = false".utf8).write(to: file, options: .atomic)
    watch.change()
    await settle { !settings.showHidden }
    await watcher.stop()
}

/// Through FSEvents: the file's folder, missing as the watch starts, is made and the file
/// written in it. FSEvents delivers on its own time, so this waits up to 5 s for the new load.
@MainActor @Test func anEditOnDiskReachesTheSettings() async throws {
    let folder = try TemporaryFolder("ConfigWatcherTests")
    let file = folder.url.appending(path: "searcher/config")
    let settings = untouchedSettings()
    let watcher = ConfigWatcher(file: file, log: { _ in })
    await settings.follow(watcher)
    #expect(!settings.showHidden)

    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: false)
    try Data("show-hidden = true".utf8).write(to: file)

    let deadline = Date(timeIntervalSinceNow: 5)
    while !settings.showHidden, Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(settings.showHidden)
    await watcher.stop()
}
