import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser

/// A store of `file` watched through `watch`.
private func store(
    _ file: URL, watch: ManualWatch = ManualWatch(), createsFolder: Bool = true,
    log: @escaping @Sendable (String) -> Void = { _ in },
    clock: ManualClock = ManualClock(),
    write: @escaping ConfigStore.Write = { try AtomicWrite.write($0, to: $1, beforeRename: $2) }
) -> ConfigStore {
    ConfigStore(
        file: file, createsFolder: createsFolder, reserved: [], fixed: [:], log: log,
        watch: watch.watch, clock: clock, write: write)
}

/// The next update the store sends, or nil when the test waited `patience` for it.
private func nextUpdate(_ updates: AsyncStream<ConfigStore.Update>) async -> ConfigStore.Update? {
    await bounded(
        Task {
            var iterator = updates.makeAsyncIterator()
            return await iterator.next()
        })
        ?? nil
}

private let showHidden = ConfigFile.Contents(values: [.showHidden: .bool(true)], shortcuts: [:])
private let foldersFirst = ConfigFile.Contents(
    values: [.foldersFirst: .bool(true)], shortcuts: [:])

@Test func startingWithNoFileLoadsNothingAndWatchesTheFolder() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let watch = ManualWatch()
    let store = store(folder.url.appending(path: "searcher/config.json"), watch: watch)

    #expect(await store.start() == .missing)
    #expect(watch.folders.all == [folder.url.appending(path: "searcher").path])
}

@Test func startingReadsTheFile() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    try Data(#"{"show-hidden": true}"#.utf8).write(to: file)

    #expect(await store(file).start() == configLoad(#"{"show-hidden": true}"#))
}

/// The store checks the file's shortcuts against the menus' reserved and fixed chords it was
/// given, so a reserved chord is an error like any other.
@Test func aReadChecksTheShortcutsAgainstTheMenusRules() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    try Data(#"{"shortcuts": {"window.showPalette": {"alternate": "cmd+q"}}}"#.utf8).write(to: file)
    let store = ConfigStore(
        file: file, createsFolder: true, reserved: [KeyChord("q", modifiers: .command)],
        fixed: [:], log: { _ in }, watch: ManualWatch().watch)

    #expect(
        await store.start().errors.map(\.key) == ["shortcuts.window.showPalette.alternate"])
}

/// An edit on disk, a replacement by an editor's atomic save and a deletion each send the load
/// that follows from the file after them, each with the next generation. A change that leaves
/// the load as it was sends none.
@Test func eachChangeOnDiskSendsTheNewLoad() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    try Data(#"{"show-hidden": true}"#.utf8).write(to: file)
    let watch = ManualWatch()
    let clock = ManualClock()
    let store = store(file, watch: watch, clock: clock)
    _ = await store.start()

    try Data(#"{ "show-hidden" : true }"#.utf8).write(to: file, options: .atomic)
    watch.change()
    try Data(#"{"folders-first": true}"#.utf8).write(to: file, options: .atomic)
    watch.change()
    #expect(
        await nextUpdate(store.updates)
            == .read(configLoad(#"{"folders-first": true}"#), generation: 1))

    let saved = folder.url.appending(path: "config.tmp")
    try Data(#"{"folders-first": false}"#.utf8).write(to: saved)
    _ = try FileManager.default.replaceItemAt(file, withItemAt: saved)
    watch.change()
    #expect(
        await nextUpdate(store.updates)
            == .read(configLoad(#"{"folders-first": false}"#), generation: 2))

    try FileManager.default.removeItem(at: file)
    // Run here rather than through the watch, so the second read's wait starts before the
    // clock moves.
    await store.reload()
    clock.advance(by: ConfigStore.confirmDelay)
    #expect(await nextUpdate(store.updates) == .read(.missing, generation: 3))
}

/// The store's own write, and a file beside it changing, as Dropbox's conflicted copies do,
/// send nothing: the next update is a real edit's.
@Test func theStoresOwnWriteSendsNoRead() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    let store = store(file)
    _ = await store.start()

    // Each reload runs here, as the watch's change would run it, so each reads the file as it
    // is at that step.
    await store.save(showHidden, basedOn: 0, sequence: 1)
    await store.reload()
    try Data("{}".utf8).write(to: folder.url.appending(path: "config (conflicted copy).json"))
    await store.reload()
    try Data(#"{"folders-first": true}"#.utf8).write(to: file, options: .atomic)
    await store.reload()

    #expect(
        await nextUpdate(store.updates)
            == .read(configLoad(#"{"folders-first": true}"#), generation: 1))
}

/// An editor's save in place passes through an empty file. A read that finds it empty waits
/// for a second read; the change that brings the new text reads it at once, so the empty file
/// is never sent, and a write meanwhile is held back rather than made over it.
@Test func anEmptyReadWaitsAndTheNextChangeSupersedesIt() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    try Data(#"{"show-hidden": true}"#.utf8).write(to: file)
    let clock = ManualClock()
    let store = store(file, clock: clock)
    _ = await store.start()

    try Data().write(to: file)
    await store.reload()
    #expect(!(await store.save(foldersFirst, basedOn: 0, sequence: 1)))
    #expect(try Data(contentsOf: file).isEmpty)
    try Data(#"{"folders-first": true}"#.utf8).write(to: file)
    await store.reload()
    clock.advance(by: ConfigStore.confirmDelay)

    #expect(
        await nextUpdate(store.updates)
            == .read(configLoad(#"{"folders-first": true}"#), generation: 1))
}

/// A file found gone, as between a sync tool's delete and create, is sent as gone only when
/// it is still gone `confirmDelay` later; one back by then sends nothing.
@Test func aFileGoneIsSentOnlyWhenASecondReadAgrees() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    let bytes = Data(#"{"show-hidden": true}"#.utf8)
    try bytes.write(to: file)
    let clock = ManualClock()
    let store = store(file, clock: clock)
    _ = await store.start()

    try FileManager.default.removeItem(at: file)
    await store.reload()
    try bytes.write(to: file)
    clock.advance(by: ConfigStore.confirmDelay)
    try Data(#"{"folders-first": true}"#.utf8).write(to: file, options: .atomic)
    await store.reload()
    #expect(
        await nextUpdate(store.updates)
            == .read(configLoad(#"{"folders-first": true}"#), generation: 1))

    try FileManager.default.removeItem(at: file)
    await store.reload()
    clock.advance(by: ConfigStore.confirmDelay)
    #expect(await nextUpdate(store.updates) == .read(.missing, generation: 2))
}

/// An edit saved while a write is under way, after the store's last read and before its
/// rename, is found by the check just before the rename: the write is dropped and the edit
/// kept and sent.
@Test func anEditSavedDuringAWriteIsKept() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    try Data("{}".utf8).write(to: file)
    let edit = Data(#"{"folders-first": true}"#.utf8)
    let store = store(
        file,
        write: { data, url, check in
            try edit.write(to: url, options: .atomic)
            try AtomicWrite.write(data, to: url, beforeRename: check)
        })
    _ = await store.start()

    #expect(!(await store.save(showHidden, basedOn: 0, sequence: 1)))

    #expect(try Data(contentsOf: file) == edit)
    #expect(
        await nextUpdate(store.updates)
            == .read(configLoad(#"{"folders-first": true}"#), generation: 1))
}

@Test func aSaveWritesTheContentsAndMakesTheDefaultFolder() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "searcher/config.json")
    let store = store(file)
    _ = await store.start()

    await store.save(showHidden, basedOn: 0, sequence: 1)

    #expect(try Data(contentsOf: file) == ConfigFile.data(showHidden))
}

/// A file that doesn't load is never written over: the user's half-finished edit is kept.
@Test func aFileWithAnErrorIsNeverWrittenOver() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    let broken = Data("{\n  \"show-hidden\": tr\n".utf8)
    try broken.write(to: file)
    let store = store(file)
    #expect(await store.start().errors.map(\.line) == [2])

    await store.save(showHidden, basedOn: 0, sequence: 1)

    #expect(try Data(contentsOf: file) == broken)
}

/// An edit saved before its change reaches the store is found when a write rereads the file,
/// sent, and wins: the write, made from settings that hadn't seen it, is dropped.
@Test func anEditNotYetSeenWinsOverAWrite() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    try Data("{}".utf8).write(to: file)
    let store = store(file)
    _ = await store.start()
    let edit = Data(#"{"folders-first": true}"#.utf8)
    try edit.write(to: file, options: .atomic)

    await store.save(showHidden, basedOn: 0, sequence: 1)

    #expect(try Data(contentsOf: file) == edit)
    #expect(
        await nextUpdate(store.updates)
            == .read(configLoad(#"{"folders-first": true}"#), generation: 1))
}

/// A write based on a read older than the last one sent, or that arrives after a later write,
/// is dropped.
@Test func aStaleWriteIsDropped() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    try Data("{}".utf8).write(to: file)
    let watch = ManualWatch()
    let store = store(file, watch: watch)
    _ = await store.start()
    try Data(#"{"hide-ds-store": false}"#.utf8).write(to: file, options: .atomic)
    watch.change()
    _ = await nextUpdate(store.updates)

    await store.save(showHidden, basedOn: 0, sequence: 1)
    #expect(try Data(contentsOf: file) == Data(#"{"hide-ds-store": false}"#.utf8))

    await store.save(foldersFirst, basedOn: 1, sequence: 3)
    await store.save(showHidden, basedOn: 1, sequence: 2)
    #expect(try Data(contentsOf: file) == ConfigFile.data(foldersFirst))
}

/// A location the user chose whose folder isn't there, as on a volume that isn't connected, is
/// an error, never a file made in its place.
@Test func aChosenFolderThatIsntThereIsAnError() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "Volumes/Dropbox/config.json")
    let store = store(file, createsFolder: false)

    let errors = await store.start().errors
    await store.save(showHidden, basedOn: 0, sequence: 1)

    #expect(errors.count == 1)
    #expect(errors.first?.reason.contains("isn't there") == true)
    #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
}

/// A file that is a symbolic link is read through it and written through it: the link stays a
/// link, as dotfiles kept in another folder need, and its target gets the settings.
@Test func aLinkIsWrittenThroughAndStaysALink() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let dotfiles = folder.url.appending(path: "dotfiles")
    try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
    let target = dotfiles.appending(path: "searcher.json")
    try Data(#"{"show-hidden": true}"#.utf8).write(to: target)
    let file = folder.url.appending(path: "config.json")
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    let watch = ManualWatch()
    let store = store(file, watch: watch)

    #expect(await store.start() == configLoad(#"{"show-hidden": true}"#))
    await store.save(foldersFirst, basedOn: 0, sequence: 1)

    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == target.path)
    #expect(try Data(contentsOf: target) == ConfigFile.data(foldersFirst))
    #expect(watch.folders.all == [folder.url.path, dotfiles.path])
}

/// A link to nothing is an error, and isn't written through.
@Test func aLinkToNothingIsAnError() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    try FileManager.default.createSymbolicLink(
        at: file, withDestinationURL: folder.url.appending(path: "missing.json"))
    let store = store(file)

    let errors = await store.start().errors
    await store.save(showHidden, basedOn: 0, sequence: 1)

    #expect(errors.first?.reason.contains("symbolic link") == true)
    #expect(
        !FileManager.default.fileExists(atPath: folder.url.appending(path: "missing.json").path))
}

/// A write that fails is sent and logged once; the next write that succeeds clears it.
@Test func aFailedWriteIsReportedUntilOneSucceeds() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    let fails = Flag(true)
    let logged = EventLog<String>()
    let store = store(
        file, log: { logged.append($0) },
        write: { data, url, check in
            if fails.isOn { throw CocoaError(.fileWriteOutOfSpace) }
            try AtomicWrite.write(data, to: url, beforeRename: check)
        })
    _ = await store.start()
    let updates = store.updates

    await store.save(showHidden, basedOn: 0, sequence: 1)
    await store.save(foldersFirst, basedOn: 0, sequence: 2)
    guard case .saved(let failure?) = await nextUpdate(updates) else {
        Issue.record("no failure was sent")
        return
    }
    #expect(failure.reason.hasPrefix("couldn't be saved"))
    #expect(logged.all.count == 1)

    fails.isOn = false
    await store.save(showHidden, basedOn: 0, sequence: 3)
    #expect(await nextUpdate(updates) == .saved(failure: nil))
}

/// Open Config File makes the file from the settings only when there is none, and says whether
/// there is one to open.
@Test func makingTheFileWritesOnlyWhenThereIsNone() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "searcher/config.json")
    let store = store(file)
    _ = await store.start()

    #expect(await store.makeIfMissing(showHidden, basedOn: 0))
    #expect(try Data(contentsOf: file) == ConfigFile.data(showHidden))
    #expect(await store.makeIfMissing(foldersFirst, basedOn: 0))
    #expect(try Data(contentsOf: file) == ConfigFile.data(showHidden))
}

/// A file with an error isn't made over, and the settings' contents don't replace it; a
/// chosen folder that isn't there has nothing to open.
@Test func makingTheFileKeepsABrokenOneAndOpensNoneForAMissingFolder() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    try Data("{".utf8).write(to: file)
    let broken = store(file)
    _ = await broken.start()
    #expect(await broken.makeIfMissing(showHidden, basedOn: 0))
    #expect(try Data(contentsOf: file) == Data("{".utf8))

    let away = store(folder.url.appending(path: "gone/config.json"), createsFolder: false)
    _ = await away.start()
    #expect(!(await away.makeIfMissing(showHidden, basedOn: 0)))
}

@Test func stoppingStopsTheWatch() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let watch = ManualWatch()
    let store = store(folder.url.appending(path: "config.json"), watch: watch)
    _ = await store.start()

    await store.stop()

    #expect(watch.stops.all.count == 1)
}

/// A folder chosen for the config file holds `config.json`; a file chosen is the file.
@Test func aChosenFolderHoldsConfigJSON() throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "mine.json")

    #expect(ConfigStore.file(forChosen: folder.url) == folder.url.appending(path: "config.json"))
    #expect(ConfigStore.file(forChosen: file) == file)
}

/// Through FSEvents: the file's folder, missing as the watch starts, is made and the file
/// written in it. A stream started since now can miss its first event under load, so the file
/// is written again every 100 ms until the read arrives, and the bound only catches a hang.
@Test func anEditOnDiskReachesTheStore() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "searcher/config.json")
    let store = ConfigStore(
        file: file, createsFolder: true, reserved: [], fixed: [:], log: { _ in })
    #expect(await store.start() == .missing)
    let expected = configLoad(#"{"show-hidden": true}"#)
    let updates = store.updates
    let arrived = Task {
        for await update in updates {
            if case .read(let load, _) = update, load == expected { return true }
        }
        return false
    }

    let writer = Task {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: false)
        for write in 1... {
            // Spaces that change each time, so each write is a change on disk.
            let text = "{" + String(repeating: " ", count: write) + #""show-hidden": true}"#
            try Data(text.utf8).write(to: file, options: .atomic)
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    let result = await bounded(arrived, seconds: patience)
    writer.cancel()
    _ = await writer.result
    await store.stop()

    #expect(result == true)
}

/// A switch a sendable closure can share with the test.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on: Bool

    init(_ on: Bool) { self.on = on }

    var isOn: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}
