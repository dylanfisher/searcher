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

/// The next update the store sends that `matching` takes, or nil when the test waited
/// `patience` for it.
private func next(
    _ updates: AsyncStream<ConfigStore.Update>,
    matching: @escaping @Sendable (ConfigStore.Update) -> Bool = { _ in true }
) async -> ConfigStore.Update? {
    await bounded(
        Task {
            for await update in updates where matching(update) { return update }
            return nil
        })
        ?? nil
}

/// The next read the store sends, skipping its writes and failures.
private func nextRead(_ updates: AsyncStream<ConfigStore.Update>) async -> ConfigLoad? {
    guard
        case .read(let load) = await next(
            updates, matching: { if case .read = $0 { true } else { false } })
    else { return nil }
    return load
}

private let none = ConfigFile.Contents(values: [:], shortcuts: [:])
private let showHidden = ConfigPatch.value(.showHidden, .bool(true))
private let foldersFirst = ConfigPatch.value(.foldersFirst, .bool(true))

/// The file's text as JSON, for a test that checks what a write kept.
private func object(_ file: URL) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
}

@Test func startingWithNoFileWritesTheContentsAndWatchesTheFolder() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "searcher/config.json")
    let watch = ManualWatch()
    let store = store(file, watch: watch)

    let contents = ConfigFile.Contents(values: [.showHidden: .bool(true)], shortcuts: [:])
    #expect(
        await store.start(writingIfMissing: contents) == ConfigFile.parse(ConfigFile.data(contents))
    )
    #expect(try Data(contentsOf: file) == ConfigFile.data(contents))
    #expect(watch.folders.all == [folder.url.appending(path: "searcher").path])
}

@Test func startingReadsTheFile() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    try Data(#"{"show-hidden": true}"#.utf8).write(to: file)

    #expect(
        await store(file).start(writingIfMissing: none) == configLoad(#"{"show-hidden": true}"#))
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
        await store.start(writingIfMissing: none).errors.map(\.key) == [
            "shortcuts.window.showPalette.alternate"
        ])
}

/// An edit on disk, a replacement by an editor's atomic save and a confirmed deletion each send
/// the load that follows from the file after them. A change that leaves the load as it was
/// sends none.
@Test func eachChangeOnDiskSendsTheNewLoad() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    try Data(#"{"show-hidden": true}"#.utf8).write(to: file)
    let clock = ManualClock()
    let store = store(file, clock: clock)
    _ = await store.start(writingIfMissing: none)

    try Data(#"{ "show-hidden" : true }"#.utf8).write(to: file, options: .atomic)
    await store.reload()
    try Data(#"{"folders-first": true}"#.utf8).write(to: file, options: .atomic)
    await store.reload()
    #expect(await nextRead(store.updates) == configLoad(#"{"folders-first": true}"#))

    let saved = folder.url.appending(path: "config.tmp")
    try Data(#"{"folders-first": false}"#.utf8).write(to: saved)
    _ = try FileManager.default.replaceItemAt(file, withItemAt: saved)
    await store.reload()
    #expect(await nextRead(store.updates) == configLoad(#"{"folders-first": false}"#))

    try FileManager.default.removeItem(at: file)
    await store.reload()
    clock.advance(by: ConfigStore.confirmDelay)
    #expect(await nextRead(store.updates) == .missing)
}

/// A patch sets its one key in the file as the file is, keeping every other key and the
/// shortcuts, and the store's own write, and a file beside it changing, as Dropbox's conflicted
/// copies do, send no read.
@Test func aPatchSetsOnlyItsKeyAndItsWriteSendsNoRead() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    try Data(#"{"appearance": "dark", "shortcuts": {"clipboard.copy": {"alternate": ""}}}"#.utf8)
        .write(to: file)
    let store = store(file)
    _ = await store.start(writingIfMissing: none)

    await store.receive(showHidden, sequence: 1)
    await store.reload()
    try Data("{}".utf8).write(to: folder.url.appending(path: "config (conflicted copy).json"))
    await store.reload()
    try Data(#"{"folders-first": true}"#.utf8).write(to: file, options: .atomic)
    await store.reload()

    #expect(await nextRead(store.updates) == configLoad(#"{"folders-first": true}"#))
}

/// The text a patch writes: the file's other keys as they were, the patched key set, sorted
/// and pretty-printed.
@Test func aPatchKeepsTheFilesOtherKeys() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    try Data(#"{"appearance": "dark", "shortcuts": {"clipboard.copy": {"alternate": ""}}}"#.utf8)
        .write(to: file)
    let store = store(file)
    _ = await store.start(writingIfMissing: none)

    await store.receive(showHidden, sequence: 1)
    await store.receive(
        .slot(CommandID("window.showPalette"), .primary, .removed), sequence: 2)

    let object = try object(file)
    #expect(object["appearance"] as? String == "dark")
    #expect(object["show-hidden"] as? Bool == true)
    #expect(object["folders-first"] == nil)
    let shortcuts = try #require(object["shortcuts"] as? [String: [String: String]])
    #expect(
        shortcuts == ["clipboard.copy": ["alternate": ""], "window.showPalette": ["primary": ""]])
    #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self).hasSuffix("}\n"))
}

/// A patch the file already holds writes nothing, so the user's spelling of the file stays.
@Test func aPatchTheFileHoldsLeavesItsBytes() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    let bytes = Data(#"{"show-hidden":true}"#.utf8)
    try bytes.write(to: file)
    let store = store(file)
    _ = await store.start(writingIfMissing: none)

    await store.receive(showHidden, sequence: 1)
    await store.receive(.value(.foldersFirst, .bool(false)), sequence: 2)
    await store.waitBounded(through: 2)

    #expect(try Data(contentsOf: file) == bytes)
}

/// A patch to a slot set back to its default takes the slot out, and the command with it.
@Test func aSlotSetToItsDefaultLeavesTheFile() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    try Data(#"{"shortcuts": {"window.showPalette": {"primary": ""}}}"#.utf8).write(to: file)
    let store = store(file)
    _ = await store.start(writingIfMissing: none)

    await store.receive(.slot(CommandID("window.showPalette"), .primary, .standard), sequence: 1)

    #expect(try object(file)["shortcuts"] as? [String: Any] != nil)
    #expect((try object(file)["shortcuts"] as? [String: Any])?.isEmpty == true)
}

/// A file that doesn't load is never written over: the patches wait, and the read sent shows
/// the errors. Once the user fixes the file, they are written on top of the fix, which keeps
/// every key the patches don't set.
@Test func patchesWaitOnABrokenFileAndApplyOnTheFix() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    let broken = Data("{\n  \"show-hidden\": tr\n".utf8)
    try broken.write(to: file)
    let store = store(file)
    #expect(await store.start(writingIfMissing: none).errors.map(\.line) == [2])

    await store.receive(showHidden, sequence: 1)
    #expect(try Data(contentsOf: file) == broken)

    try Data(#"{"show-hidden": false, "appearance": "dark"}"#.utf8).write(
        to: file, options: .atomic)
    await store.reload()
    await store.waitBounded(through: 1)

    let object = try object(file)
    #expect(object["show-hidden"] as? Bool == true)
    #expect(object["appearance"] as? String == "dark")
    #expect(
        await nextRead(store.updates)
            == configLoad(#"{"show-hidden": true, "appearance": "dark"}"#))
}

/// An editor's save in place passes through an empty file. A read that finds it empty waits
/// for a second read; the change that brings the new text reads it at once, so the empty file
/// is never sent, and a patch meanwhile waits rather than be written over it.
@Test func anEmptyReadWaitsAndTheNextChangeSupersedesIt() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    try Data(#"{"show-hidden": true}"#.utf8).write(to: file)
    let clock = ManualClock()
    let store = store(file, clock: clock)
    _ = await store.start(writingIfMissing: none)

    try Data().write(to: file)
    await store.reload()
    await store.receive(foldersFirst, sequence: 1)
    #expect(try Data(contentsOf: file).isEmpty)
    try Data(#"{"appearance": "dark"}"#.utf8).write(to: file)
    await store.reload()
    clock.advance(by: ConfigStore.confirmDelay)
    await store.waitBounded(through: 1)

    #expect(
        await nextRead(store.updates)
            == configLoad(#"{"appearance": "dark", "folders-first": true}"#))
    #expect(try object(file)["appearance"] as? String == "dark")
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
    _ = await store.start(writingIfMissing: none)

    try FileManager.default.removeItem(at: file)
    await store.reload()
    try bytes.write(to: file)
    clock.advance(by: ConfigStore.confirmDelay)
    try Data(#"{"folders-first": true}"#.utf8).write(to: file, options: .atomic)
    await store.reload()
    #expect(await nextRead(store.updates) == configLoad(#"{"folders-first": true}"#))

    try FileManager.default.removeItem(at: file)
    await store.reload()
    clock.advance(by: ConfigStore.confirmDelay)
    #expect(await nextRead(store.updates) == .missing)
}

/// A patch that comes while the file is gone, once the deletion is confirmed, is written as a
/// new file: the defaults with the patch.
@Test func aPatchDuringADeletionWritesANewFile() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    try Data(#"{"appearance": "dark"}"#.utf8).write(to: file)
    let clock = ManualClock()
    let store = store(file, clock: clock)
    _ = await store.start(writingIfMissing: none)

    try FileManager.default.removeItem(at: file)
    await store.reload()
    await store.receive(showHidden, sequence: 1)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    clock.advance(by: ConfigStore.confirmDelay)
    await store.waitBounded(through: 1)

    #expect(
        try Data(contentsOf: file)
            == ConfigFile.data(.init(values: [.showHidden: .bool(true)], shortcuts: [:])))
    #expect(await nextRead(store.updates)?.values == [.showHidden: .bool(true)])
}

/// An edit saved while a write is under way, after the store's read and before its rename, is
/// found by the check just before the rename: the write starts over from the edit, which keeps
/// its key.
@Test func anEditSavedDuringAWriteIsKept() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    try Data("{}".utf8).write(to: file)
    let edited = Flag(false)
    let store = store(
        file,
        write: { data, url, check in
            if !edited.isOn {
                edited.isOn = true
                try Data(#"{"folders-first": true}"#.utf8).write(to: url, options: .atomic)
            }
            try AtomicWrite.write(data, to: url, beforeRename: check)
        })
    _ = await store.start(writingIfMissing: none)

    await store.receive(showHidden, sequence: 1)

    let object = try object(file)
    #expect(object["folders-first"] as? Bool == true)
    #expect(object["show-hidden"] as? Bool == true)
}

/// A location the user chose whose folder isn't there, as on a volume that isn't connected, is
/// an error, never a file made in its place.
@Test func aChosenFolderThatIsntThereIsAnError() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "Volumes/Dropbox/config.json")
    let store = store(file, createsFolder: false)

    let errors = await store.start(writingIfMissing: none).errors
    await store.receive(showHidden, sequence: 1)

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

    #expect(
        await store.start(writingIfMissing: none) == configLoad(#"{"show-hidden": true}"#))
    await store.receive(foldersFirst, sequence: 1)

    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == target.path)
    #expect(try object(target)["folders-first"] as? Bool == true)
    #expect(watch.folders.all == [folder.url.path, dotfiles.path])
}

/// A link to nothing is an error, and isn't written through.
@Test func aLinkToNothingIsAnError() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    try FileManager.default.createSymbolicLink(
        at: file, withDestinationURL: folder.url.appending(path: "missing.json"))
    let store = store(file)

    let errors = await store.start(writingIfMissing: none).errors
    await store.receive(showHidden, sequence: 1)

    #expect(errors.first?.reason.contains("symbolic link") == true)
    #expect(
        !FileManager.default.fileExists(atPath: folder.url.appending(path: "missing.json").path))
}

/// A write that fails keeps its patch, is shown once, and is tried again after a wait that
/// doubles each time, up to `longestRetryDelay`; the write that succeeds clears the failure.
@Test func aFailedWriteIsRetriedWithBackoff() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    try Data("{}".utf8).write(to: file)
    let fails = Flag(true)
    let tries = EventLog<Void>()
    let logged = EventLog<String>()
    let clock = ManualClock()
    let store = store(
        file, log: { logged.append($0) }, clock: clock,
        write: { data, url, check in
            tries.append(())
            if fails.isOn { throw CocoaError(.fileWriteNoPermission) }
            try AtomicWrite.write(data, to: url, beforeRename: check)
        })
    _ = await store.start(writingIfMissing: none)
    let updates = store.updates

    await store.receive(showHidden, sequence: 1)
    guard case .saved(let failure?) = await next(updates) else {
        Issue.record("no failure was sent")
        return
    }
    #expect(failure.reason.hasPrefix("couldn't be saved"))
    #expect(tries.all.count == 1)

    // Each retry waits twice as long as the one before, up to the cap.
    var delay = ConfigStore.firstRetryDelay
    for attempt in 2...7 {
        await settle { clock.waitingSleeps == 1 }
        clock.advance(by: delay - .milliseconds(1))
        // Still asleep a moment before its delay: the clock wakes a due sleep as it moves.
        #expect(clock.waitingSleeps == 1)
        #expect(tries.all.count == attempt - 1)
        clock.advance(by: .milliseconds(1))
        await settle { tries.all.count == attempt }
        delay = min(delay * 2, ConfigStore.longestRetryDelay)
    }
    #expect(delay == ConfigStore.longestRetryDelay)
    #expect(logged.all.count == 1)

    fails.isOn = false
    await settle { clock.waitingSleeps == 1 }
    clock.advance(by: delay)
    await store.waitBounded(through: 1)
    #expect(try object(file)["show-hidden"] as? Bool == true)
    #expect(await next(updates, matching: { $0 == .saved(failure: nil) }) == .saved(failure: nil))
}

/// A patch whose write failed waits for its retry; an editor's save of the same key meanwhile
/// came later, so it drops the patch, and the retry writes nothing over the save.
@Test func anEditDuringARetryDropsTheHeldPatch() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    try Data(#"{"appearance": "auto"}"#.utf8).write(to: file)
    let fails = Flag(true)
    let clock = ManualClock()
    let store = store(
        file, clock: clock,
        write: { data, url, check in
            if fails.isOn { throw CocoaError(.fileWriteNoPermission) }
            try AtomicWrite.write(data, to: url, beforeRename: check)
        })
    _ = await store.start(writingIfMissing: none)
    let updates = store.updates

    await store.receive(.value(.appearance, .string("light")), sequence: 1)
    let edit = Data(#"{"appearance": "dark"}"#.utf8)
    try edit.write(to: file, options: .atomic)
    await store.reload()
    fails.isOn = false
    clock.advance(by: ConfigStore.longestRetryDelay)
    await store.waitBounded(through: 1)

    #expect(try Data(contentsOf: file) == edit)
    #expect(
        await next(updates, matching: { if case .superseded = $0 { true } else { false } })
            == .superseded(sequences: [1]))
}

/// A write whose file changes during every attempt shows that it couldn't be saved while it
/// waits for its retry.
@Test func aWriteThatKeepsMeetingEditsShowsItCouldntBeSaved() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    try Data("{}".utf8).write(to: file)
    let edits = EventLog<Void>()
    let store = store(
        file,
        write: { data, url, check in
            edits.append(())
            try Data("{\(String(repeating: " ", count: edits.all.count))}".utf8).write(
                to: url, options: .atomic)
            try AtomicWrite.write(data, to: url, beforeRename: check)
        })
    _ = await store.start(writingIfMissing: none)
    let updates = store.updates

    await store.receive(showHidden, sequence: 1)

    guard
        case .saved(let failure?) = await next(
            updates, matching: { if case .saved = $0 { true } else { false } })
    else {
        Issue.record("no failure was sent")
        return
    }
    #expect(failure.reason.contains("changed during each of"))
    #expect(edits.all.count == ConfigStore.attempts)
}

/// Open Config File makes the file from the settings only when there is none, and says whether
/// there is one to open.
@Test func makingTheFileWritesOnlyWhenThereIsNone() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "searcher/config.json")
    let store = store(file, createsFolder: true)
    let first = ConfigFile.Contents(values: [.showHidden: .bool(true)], shortcuts: [:])
    _ = await store.start(writingIfMissing: first)
    try FileManager.default.removeItem(at: file)

    let second = ConfigFile.Contents(values: [.foldersFirst: .bool(true)], shortcuts: [:])
    #expect(await store.makeIfMissing(second))
    #expect(try Data(contentsOf: file) == ConfigFile.data(second))
    #expect(await store.makeIfMissing(first))
    #expect(try Data(contentsOf: file) == ConfigFile.data(second))
}

/// A file with an error isn't made over; a chosen folder that isn't there has nothing to open.
@Test func makingTheFileKeepsABrokenOneAndOpensNoneForAMissingFolder() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    try Data("{".utf8).write(to: file)
    let broken = store(file)
    _ = await broken.start(writingIfMissing: none)
    #expect(await broken.makeIfMissing(none))
    #expect(try Data(contentsOf: file) == Data("{".utf8))

    let away = store(folder.url.appending(path: "gone/config.json"), createsFolder: false)
    _ = await away.start(writingIfMissing: none)
    #expect(!(await away.makeIfMissing(none)))
}

/// Stopping stops the watch and lets go of a wait for a write that can't happen.
@Test func stoppingStopsTheWatchAndTheWaits() async throws {
    let folder = try TemporaryFolder("ConfigStoreTests")
    let file = folder.url.appending(path: "config.json")
    try Data("{".utf8).write(to: file)
    let watch = ManualWatch()
    let store = store(file, watch: watch)
    _ = await store.start(writingIfMissing: none)
    await store.receive(showHidden, sequence: 1)
    let waiting = Task { await store.waitUntilWritten(through: 1) }

    await store.stop()

    _ = await bounded(waiting)
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
    // A chosen place, so the store doesn't make the folder itself; until it is made, the
    // folder missing is an error.
    let store = ConfigStore(
        file: file, createsFolder: false, reserved: [], fixed: [:], log: { _ in })
    #expect(!(await store.start(writingIfMissing: none)).errors.isEmpty)
    let expected = configLoad(#"{"show-hidden": true}"#)
    let updates = store.updates
    let arrived = Task {
        for await update in updates where update == .read(expected) { return true }
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
