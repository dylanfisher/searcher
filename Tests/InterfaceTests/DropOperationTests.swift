import AppKit
import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

// MARK: Finder's table

/// The mask AppKit gives a destination for each set of keys held, from a source that allows
/// every operation, as Finder and the list do.
private let noKeys: NSDragOperation = [.copy, .move, .generic, .link]
private let option: NSDragOperation = .copy
private let command: NSDragOperation = .generic
private let commandOption: NSDragOperation = .link

/// A table of `/` and a disk at `/Volumes/disk`, once it has been read.
@MainActor
private func twoVolumes() async -> MountTable {
    let table = MountTable(read: {
        [
            VolumeIdentity(device: "/dev/disk3s1", mountPoint: "/", kind: .local),
            VolumeIdentity(device: "/dev/disk5s1", mountPoint: "/Volumes/disk", kind: .local),
        ]
    })
    await settle { table.volume(of: "/") != nil }
    return table
}

@MainActor @Test func dropsFollowFindersTableForEachKeyAndVolumePair() async {
    let mounts = await twoVolumes()
    let home = ["/Users/someone/a.txt"]
    let disk = ["/Volumes/disk/b.txt"]
    let cases: [(String, [String], NSDragOperation, DropOperation?)] = [
        ("same volume", home, noKeys, .move),
        ("other volume", disk, noKeys, .copy),
        ("same volume, Option", home, option, .copy),
        ("other volume, Option", disk, option, .copy),
        ("same volume, Command", home, command, .move),
        ("other volume, Command", disk, command, .move),
        // Finder makes an alias; Searcher makes none.
        ("same volume, Command-Option", home, commandOption, nil),
    ]
    for (name, sources, mask, expected) in cases {
        let operation = DropOperation(
            dropping: sources, into: "/Users/someone/Documents", allowed: mask, mounts: mounts)
        #expect(operation == expected, "\(name)")
    }
}

@MainActor @Test func aDropFromOneVolumeOrOneOfSeveralCopies() async {
    let mounts = await twoVolumes()

    let mixed = DropOperation(
        dropping: ["/Users/someone/a.txt", "/Volumes/disk/b.txt"], into: "/Users/someone/c",
        allowed: noKeys, mounts: mounts)

    #expect(mixed == .copy)
}

@MainActor @Test func aSourceThatAllowsOnlyACopyCopies() async {
    let mounts = await twoVolumes()

    let operation = DropOperation(
        dropping: ["/Users/someone/a.txt"], into: "/Users/someone/c", allowed: .copy,
        mounts: mounts)

    #expect(operation == .copy)
}

@MainActor @Test func aDropIntoItselfOrItsOwnFolderIsRefused() async {
    let mounts = await twoVolumes()
    func operation(_ sources: [String], into folder: String) -> DropOperation? {
        DropOperation(dropping: sources, into: folder, allowed: noKeys, mounts: mounts)
    }

    #expect(operation(["/Users/someone/Photos"], into: "/Users/someone/Photos") == nil)
    #expect(operation(["/Users/someone/Photos"], into: "/Users/someone/photos/2024") == nil)
    // Every item is in the folder already, so there is nothing to do.
    #expect(operation(["/Users/someone/a.txt", "/Users/someone/b"], into: "/Users/someone") == nil)
    #expect(operation([], into: "/Users/someone") == nil)
}

@MainActor @Test func optionDraggingItemsIntoTheirOwnFolderDuplicatesThem() async {
    let mounts = await twoVolumes()
    let sources = ["/Users/someone/a.txt", "/Users/someone/b"]
    func operation(_ mask: NSDragOperation) -> DropOperation? {
        DropOperation(dropping: sources, into: "/Users/someone", allowed: mask, mounts: mounts)
    }

    #expect(operation(option) == .duplicate)
    #expect(operation(noKeys) == nil)
    #expect(operation(command) == nil)
    #expect(operation(commandOption) == nil)
    #expect(DropOperation.duplicate.dragOperation(allowed: option) == .copy)
    #expect(
        DropOperation.duplicate.fileOperation(sources, into: "/Users/someone")
            == .duplicate(sources))
}

@MainActor @Test func aPathOnNoKnownVolumeCopies() async {
    let table = MountTable(read: { [] })
    await settle { table.isRead }

    let operation = DropOperation(
        dropping: ["/Users/someone/a.txt"], into: "/Users/someone/c", allowed: noKeys,
        mounts: table)

    #expect(operation == .copy)
}

// MARK: Dropping on the list

/// A pane over a real temporary folder holding `a.txt` and the folder `sub`, and the packages
/// `Tool.app` and `Notes.rtfd` when `packages` is true, in a window that is never shown, with a
/// queue of its own that traps on any question, and a second folder `elsewhere` to drag from.
/// `/` is the only volume unless a test says otherwise.
@MainActor
private final class Fixture {
    let root: TemporaryFolder
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled],
        backing: .buffered, defer: true)
    let actions = StubSystemActions()
    let pane: Pane
    let controller: PaneViewController
    let queue: FileOperationQueue
    let snapshots = EventLog<FileOperationQueue.Snapshot>()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("searcher-test-\(UUID().uuidString)"))

    var folder: URL { root.url.appending(path: "pane") }
    var elsewhere: URL { root.url.appending(path: "elsewhere") }
    var list: ListingViewController { controller.listingViewController }
    var table: ListingTableView { list.tableView }

    init(otherVolume: Bool = false, packages: Bool = false) async throws {
        root = try TemporaryFolder("DropOperationTests")
        let folder = root.url.appending(path: "pane")
        let elsewhere = root.url.appending(path: "elsewhere")
        for url in [folder, elsewhere, folder.appending(path: "sub")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        try Data("a".utf8).write(to: folder.appending(path: "a.txt"))
        for name in ["x.txt", "y.txt"] {
            try Data(name.utf8).write(to: elsewhere.appending(path: name))
        }
        for name in packages ? ["Tool.app", "Notes.rtfd"] : [] {
            try FileManager.default.createDirectory(
                at: folder.appending(path: name), withIntermediateDirectories: false)
        }
        pane = Pane(
            location: Location(path: folder.path), service: ListingService(),
            systemActions: actions, settings: untouchedSettings(), isFocused: true)
        controller = PaneViewController(
            pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
            tableView: ListingTableView(), monitorsFolders: true)
        let snapshots = snapshots
        queue = FileOperationQueue(
            prompts: .unexpected
        ) { reported in
            for snapshot in reported { snapshots.append(snapshot) }
        }
        var volumes = [VolumeIdentity(device: "/dev/disk3s1", mountPoint: "/", kind: .local)]
        if otherVolume {
            volumes.append(
                VolumeIdentity(device: "/dev/disk5s1", mountPoint: elsewhere.path, kind: .local))
        }
        let mounts = MountTable(read: { [volumes] in volumes })
        window.isReleasedWhenClosed = false
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        window.contentView?.addSubview(controller.view)
        let pane = pane
        await settle { pane.state.isLoaded && pane.monitor != nil && mounts.isRead }
        list.fileOperations = queue
        list.mountTable = mounts
    }

    /// Stops the monitor and releases the pasteboard before the folder goes.
    func stop() {
        pane.monitor?.stop()
        pasteboard.releaseGlobally()
    }

    /// Puts `urls` on the drag's pasteboard as Finder writes them, and returns its info.
    func drag(_ urls: [URL], mask: NSDragOperation = noKeys) -> StubDraggingInfo {
        pasteboard.clearContents()
        let items = urls.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
        #expect(pasteboard.writeObjects(items))
        // A drop reads the URLs back; if the pasteboard server gave none, the drop would be nil and
        // a test would fail far from the cause.
        #expect(
            PasteboardFileClipboard(pasteboard: pasteboard).fileURLs().map(\.path)
                == urls.map(\.path))
        return StubDraggingInfo(pasteboard: pasteboard, mask: mask)
    }

    func row(_ name: String) throws -> Int {
        try #require(pane.state.listing?.row(named: name))
    }

    func validate(
        _ info: StubDraggingInfo, row: Int, _ operation: NSTableView.DropOperation
    ) -> NSDragOperation {
        list.tableView(
            table, validateDrop: info, proposedRow: row, proposedDropOperation: operation)
    }

    func accept(_ info: StubDraggingInfo, row: Int, _ operation: NSTableView.DropOperation) -> Bool
    {
        list.tableView(table, acceptDrop: info, row: row, dropOperation: operation)
    }

    /// Waits for `done` and for the queue to have reported the operation. The files change before
    /// the queue's report reaches `snapshots`, so `done` alone can pass while `operations` is
    /// still empty.
    func settleOperation(
        fileID: String = #fileID, filePath: String = #filePath, line: Int = #line,
        column: Int = #column, until done: @MainActor () -> Bool
    ) async {
        await settle(fileID: fileID, filePath: filePath, line: line, column: column) {
            done() && !operations.isEmpty
        }
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    var operations: [FileOperation] {
        var seen: [FileOperationQueue.ID: FileOperation] = [:]
        for snapshot in snapshots.all { seen[snapshot.id] = snapshot.operation }
        return seen.keys.sorted().compactMap { seen[$0] }
    }

    var selectedNames: Set<String> {
        guard pane.selection.isSettled, case .only(let names) = pane.selection.members else {
            return []
        }
        return Set(names.map(\.name))
    }
}

@MainActor @Test func aDropOnAFolderRowMovesIntoThatFolder() async throws {
    let fixture = try await Fixture()
    defer { fixture.stop() }
    let source = fixture.elsewhere.appending(path: "x.txt")
    let info = fixture.drag([source])
    let row = try fixture.row("sub")

    #expect(fixture.validate(info, row: row, .on) == .move)
    #expect(fixture.accept(info, row: row, .on))

    let target = fixture.folder.appending(path: "sub/x.txt")
    await fixture.settleOperation { fixture.exists(target) && !fixture.exists(source) }
    #expect(
        fixture.operations == [
            .move([source.path], into: fixture.folder.appending(path: "sub").path)
        ])
}

/// A drop's operation is tagged with the workspace of the window the list is in, so that
/// window's operations panel lists it.
@MainActor @Test func aDropsOperationCarriesTheListsWorkspace() async throws {
    let fixture = try await Fixture()
    defer { fixture.stop() }
    let workspace = UUID()
    fixture.list.workspaceID = workspace
    let source = fixture.elsewhere.appending(path: "x.txt")
    let info = fixture.drag([source])

    #expect(fixture.accept(info, row: try fixture.row("sub"), .on))

    await fixture.settleOperation { !fixture.exists(source) }
    #expect(!fixture.snapshots.all.isEmpty)
    #expect(fixture.snapshots.all.allSatisfy { $0.workspace == workspace })
}

@MainActor @Test func aDropBetweenRowsOrOnAFileTargetsThePanesFolder() async throws {
    let fixture = try await Fixture()
    defer { fixture.stop() }
    let source = fixture.elsewhere.appending(path: "x.txt")
    let info = fixture.drag([source])

    #expect(fixture.validate(info, row: try fixture.row("a.txt"), .on) == .move)
    #expect(fixture.validate(info, row: 1, .above) == .move)
    #expect(fixture.validate(info, row: -1, .on) == .move)
    #expect(fixture.accept(info, row: try fixture.row("a.txt"), .on))

    await fixture.settleOperation { fixture.exists(fixture.folder.appending(path: "x.txt")) }
    #expect(fixture.operations == [.move([source.path], into: fixture.folder.path)])
}

@MainActor @Test func aDropIssuesOneQueuedOperationWithoutAConfirmAndSelectsWhatItMoved()
    async throws
{
    let fixture = try await Fixture()
    defer { fixture.stop() }
    let sources = ["x.txt", "y.txt"].map { fixture.elsewhere.appending(path: $0) }

    #expect(fixture.accept(fixture.drag(sources), row: -1, .on))

    await fixture.settleOperation { fixture.selectedNames == ["x.txt", "y.txt"] }
    #expect(fixture.operations == [.move(sources.map(\.path), into: fixture.folder.path)])
}

@MainActor @Test func anOptionDropFromThePanesOwnFolderQueuesADuplicateAndSelectsIt()
    async throws
{
    let fixture = try await Fixture()
    defer { fixture.stop() }
    let a = fixture.folder.appending(path: "a.txt")
    let info = fixture.drag([a], mask: option)

    #expect(fixture.validate(info, row: -1, .on) == .copy)
    #expect(fixture.validate(info, row: try fixture.row("a.txt"), .on) == .copy)
    #expect(fixture.accept(info, row: try fixture.row("a.txt"), .on))

    await fixture.settleOperation { fixture.exists(fixture.folder.appending(path: "a copy.txt")) }
    await settle { fixture.selectedNames == ["a copy.txt"] }
    #expect(fixture.exists(a))
    #expect(fixture.operations == [.duplicate([a.path])])
}

@MainActor @Test func optionCopiesAndADropFromAnotherVolumeCopies() async throws {
    let fixture = try await Fixture(otherVolume: true)
    defer { fixture.stop() }
    let x = fixture.elsewhere.appending(path: "x.txt")

    let info = fixture.drag([x])
    #expect(fixture.validate(info, row: -1, .on) == .copy)
    #expect(fixture.validate(fixture.drag([x], mask: command), row: -1, .on) == .generic)
    #expect(fixture.accept(fixture.drag([x], mask: option), row: -1, .on))

    await fixture.settleOperation { fixture.exists(fixture.folder.appending(path: "x.txt")) }
    #expect(fixture.exists(x))
    #expect(fixture.operations == [.copy([x.path], into: fixture.folder.path)])
}

@MainActor @Test func aDropFromThePanesOwnFolderOrIntoItselfDoesNothing() async throws {
    let fixture = try await Fixture()
    defer { fixture.stop() }
    let own = fixture.drag([fixture.folder.appending(path: "a.txt")])
    #expect(fixture.validate(own, row: -1, .on) == [])
    #expect(!fixture.accept(own, row: -1, .on))

    let sub = fixture.drag([fixture.folder.appending(path: "sub")])
    #expect(fixture.validate(sub, row: try fixture.row("sub"), .on) == [])
    #expect(!fixture.accept(sub, row: try fixture.row("sub"), .on))

    let parent = fixture.drag([fixture.folder])
    #expect(fixture.validate(parent, row: -1, .on) == [])

    try await Task.sleep(for: .milliseconds(100))
    #expect(fixture.operations.isEmpty)
}

/// Finder opens files dropped on an app with that app, and moves nothing into the app.
@MainActor @Test func aDropOnAnAppRowOpensTheFilesWithTheApp() async throws {
    let fixture = try await Fixture(packages: true)
    defer { fixture.stop() }
    let sources = ["x.txt", "y.txt"].map { fixture.elsewhere.appending(path: $0) }
    let info = fixture.drag(sources)
    let row = try fixture.row("Tool.app")

    #expect(fixture.validate(info, row: row, .on) == .generic)
    #expect(fixture.accept(info, row: row, .on))

    let opened = fixture.actions.openedWithApp
    #expect(opened.map { $0.urls.map(\.path) } == [sources.map(\.path)])
    #expect(opened.map(\.application.path) == [fixture.folder.path + "/Tool.app"])
    try await Task.sleep(for: .milliseconds(100))
    #expect(fixture.operations.isEmpty)
    #expect(fixture.exists(sources[0]))
}

/// A package that isn't an app is a file: a drop on its row goes to the pane's folder, as a drop
/// on a file's row does, and nothing goes inside it.
@MainActor @Test func aDropOnAnotherPackagesRowTargetsThePanesFolder() async throws {
    let fixture = try await Fixture(packages: true)
    defer { fixture.stop() }
    let source = fixture.elsewhere.appending(path: "x.txt")
    let info = fixture.drag([source])
    let row = try fixture.row("Notes.rtfd")

    #expect(fixture.validate(info, row: row, .on) == .move)
    #expect(fixture.accept(info, row: row, .on))

    await fixture.settleOperation { fixture.exists(fixture.folder.appending(path: "x.txt")) }
    #expect(fixture.operations == [.move([source.path], into: fixture.folder.path)])
    #expect(fixture.actions.openedWithApp.isEmpty)
}

/// An app dragged onto its own row opens nothing.
@MainActor @Test func anAppDroppedOnItselfIsRefused() async throws {
    let fixture = try await Fixture(packages: true)
    defer { fixture.stop() }
    let info = fixture.drag([fixture.folder.appending(path: "Tool.app")])

    #expect(fixture.validate(info, row: try fixture.row("Tool.app"), .on) == [])
    #expect(!fixture.accept(info, row: try fixture.row("Tool.app"), .on))
    #expect(fixture.actions.openedWithApp.isEmpty)
}

@MainActor @Test func aListWithoutAQueueTakesNoDrop() async throws {
    let fixture = try await Fixture()
    defer { fixture.stop() }
    fixture.list.fileOperations = nil
    let info = fixture.drag([fixture.elsewhere.appending(path: "x.txt")])

    #expect(fixture.validate(info, row: -1, .on) == [])
    #expect(!fixture.accept(info, row: -1, .on))
}

@MainActor @Test func theListTakesFileURLsAndFilePromises() async throws {
    let fixture = try await Fixture()
    defer { fixture.stop() }
    let types = Set(fixture.table.registeredDraggedTypes)

    #expect(types.contains(.fileURL))
    for type in NSFilePromiseReceiver.readableDraggedTypes {
        #expect(types.contains(NSPasteboard.PasteboardType(type)))
    }
}

/// Promises one file of the photo's name and writes it when called in, as Photos does.
private final class PhotoPromiser: NSObject, NSFilePromiseProviderDelegate {
    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String
    ) -> String { "photo.jpg" }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        completionHandler(nil)
    }
}

@MainActor @Test func aFilePromiseDropValidatesAsACopy() async throws {
    let fixture = try await Fixture()
    defer { fixture.stop() }
    let promiser = PhotoPromiser()
    fixture.pasteboard.clearContents()
    let provider = NSFilePromiseProvider(fileType: "public.jpeg", delegate: promiser)
    #expect(fixture.pasteboard.writeObjects([provider]))
    let info = StubDraggingInfo(pasteboard: fixture.pasteboard, mask: noKeys)

    #expect(fixture.validate(info, row: -1, .on) == .copy)
    #expect(fixture.validate(info, row: try fixture.row("sub"), .on) == .copy)
}

/// A promise that writes `name` into the folder it is called into from another thread, as a
/// source app does, fails, or never answers.
private final class StubPromise: FilePromiseReceiver.Promise, @unchecked Sendable {
    enum Outcome {
        case writes, fails, hangs
    }

    let name: String
    let outcome: Outcome

    init(_ name: String, _ outcome: Outcome = .writes) {
        self.name = name
        self.outcome = outcome
    }

    func receive(
        into folder: URL, reader: @escaping @Sendable (URL, (any Error)?) -> Void
    ) -> Int {
        let url = folder.appending(path: name)
        switch outcome {
        case .hangs:
            break
        case .fails:
            DispatchQueue.global().async {
                reader(url, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            }
        case .writes:
            DispatchQueue.global().async {
                do {
                    try Data("promised".utf8).write(to: url)
                    reader(url, nil)
                } catch {
                    reader(url, error)
                }
            }
        }
        return 1
    }
}

extension Fixture {
    /// The last state of each drop failure the queue reported.
    var reportedFailures: [(FileOperation, OperationState)] {
        var seen: [FileOperationQueue.ID: (FileOperation, OperationState)] = [:]
        for snapshot in snapshots.all {
            guard case .receive = snapshot.operation else { continue }
            seen[snapshot.id] = (snapshot.operation, snapshot.state)
        }
        return seen.keys.sorted().compactMap { seen[$0] }
    }

    func contents(of url: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: url.path))
    }

    /// The hidden folder a drop under way receives its files in.
    func dropFolder() throws -> URL {
        let name = try #require(try contents(of: folder).first { $0.hasPrefix(".") })
        return folder.appending(path: name)
    }
}

@MainActor @Test func promisedFilesLandInTheTargetFolderAndAreSelected() async throws {
    let fixture = try await Fixture()
    defer { fixture.stop() }

    await FilePromiseReceiver.receive(
        [StubPromise("photo.jpg"), StubPromise("mail.eml")], into: fixture.folder.path,
        from: "Photos", selectingIn: fixture.pane, queue: fixture.queue)

    #expect(try fixture.contents(of: fixture.folder) == ["a.txt", "sub", "photo.jpg", "mail.eml"])
    await settle { fixture.selectedNames == ["photo.jpg", "mail.eml"] }
    #expect(fixture.operations.count == 1)
    #expect(fixture.reportedFailures.isEmpty)
}

@MainActor @Test func aPromisedFileThatFailsShowsAsAFailedDropNamedAfterIt() async throws {
    let fixture = try await Fixture()
    defer { fixture.stop() }

    await FilePromiseReceiver.receive(
        [StubPromise("photo.jpg"), StubPromise("lost.jpg", .fails)], into: fixture.folder.path,
        from: "Photos", selectingIn: fixture.pane, queue: fixture.queue)

    #expect(try fixture.contents(of: fixture.folder) == ["a.txt", "sub", "photo.jpg"])
    await settle { !fixture.reportedFailures.isEmpty }
    let (operation, state) = try #require(fixture.reportedFailures.first)
    #expect(operation == .receive(name: "lost.jpg", app: "Photos", into: fixture.folder.path))
    #expect(state.phase == .failed)
    #expect(
        state.errors == [
            FileOperationError(errno: EIO, path: fixture.folder.appending(path: "lost.jpg").path)
        ])
}

@MainActor @Test func aDropIntoAReadOnlyFolderShowsAsAFailedDrop() async throws {
    let fixture = try await Fixture()
    defer { fixture.stop() }
    let sub = fixture.folder.appending(path: "sub")
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sub.path)
    defer {
        _ = try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: sub.path)
    }

    await FilePromiseReceiver.receive(
        [StubPromise("photo.jpg")], into: sub.path, from: "Mail", selectingIn: nil,
        queue: fixture.queue)

    await settle { !fixture.reportedFailures.isEmpty }
    let (operation, state) = try #require(fixture.reportedFailures.first)
    #expect(operation == .receive(name: nil, app: "Mail", into: sub.path))
    #expect(state.phase == .failed)
    #expect(state.errors.map(\.reason) == [.permissionDenied])
    #expect(try fixture.contents(of: sub).isEmpty)
}

/// A promise whose file the test writes a piece at a time, then finishes or abandons.
private final class GrowingPromise: FilePromiseReceiver.Promise, @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private var call: (url: URL, reader: @Sendable (URL, (any Error)?) -> Void)?

    init(_ name: String) {
        self.name = name
    }

    var isCalledIn: Bool { lock.withLock { call != nil } }

    func receive(
        into folder: URL, reader: @escaping @Sendable (URL, (any Error)?) -> Void
    ) -> Int {
        lock.withLock { call = (folder.appending(path: name), reader) }
        return 1
    }

    /// Adds a kilobyte to the file.
    func grow() throws {
        let url = try #require(lock.withLock { call?.url })
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: 1024))
    }

    func finish() throws {
        let call = try #require(lock.withLock { self.call })
        call.reader(call.url, nil)
    }

    /// Removes what was written, so the drop's cleanup has nothing to put in the Trash.
    func abandon() throws {
        let url = try #require(lock.withLock { call?.url })
        try FileManager.default.removeItem(at: url)
    }
}

/// Whether a drop running in a task has returned.
@MainActor
private final class Finished {
    var value = false
}

/// Starts `promises`' drop into the fixture's folder on `clock`, and waits for its first read
/// of the folder's size to be due.
@MainActor
private func startDrop(
    _ promises: [any FilePromiseReceiver.Promise], _ fixture: Fixture, clock: ManualClock
) async -> Finished {
    let finished = Finished()
    Task {
        await FilePromiseReceiver.receive(
            promises, into: fixture.folder.path, from: "Mail", selectingIn: nil,
            queue: fixture.queue, clock: clock)
        finished.value = true
    }
    await settle { clock.waitingSleeps == 1 }
    return finished
}

/// Moves the clock to the drop's next read of its folder's size, and waits until it has read
/// it and waits for the next one.
@MainActor
private func nextRead(_ clock: ManualClock) async {
    clock.advance(by: FilePromiseReceiver.progressInterval)
    await settle { clock.waitingSleeps == 1 }
}

/// Waits for the drop to return, failing the test with a message rather than hanging when it
/// doesn't.
@MainActor
private func waitForTheDrop(_ finished: Finished, _ what: String) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: 5)
    while !finished.value, Date() < deadline {
        try? await Task.sleep(for: .milliseconds(2))
    }
    if !finished.value { Issue.record("the drop never returned: \(what)") }
    return finished.value
}

/// The reads of the folder's size that make up the idle timeout.
private let readsToTimeOut = Int(
    FilePromiseReceiver.idleTimeout / FilePromiseReceiver.progressInterval)

@MainActor @Test func aSourceThatStopsAnsweringTimesOutAndTheDropIsCleanedUp() async throws {
    let fixture = try await Fixture()
    defer { fixture.stop() }
    let clock = ManualClock()
    let finished = await startDrop([StubPromise("never.jpg", .hangs)], fixture, clock: clock)
    let dropFolder = try fixture.dropFolder()

    for _ in 1..<readsToTimeOut { await nextRead(clock) }
    #expect(!finished.value)
    #expect(fixture.reportedFailures.isEmpty)
    clock.advance(by: FilePromiseReceiver.progressInterval)
    guard await waitForTheDrop(finished, "the idle timeout didn't end it") else { return }

    // The hidden folder is gone.
    #expect(try fixture.contents(of: fixture.folder) == ["a.txt", "sub"])
    await settle { !fixture.reportedFailures.isEmpty }
    let (operation, state) = try #require(fixture.reportedFailures.first)
    #expect(operation == .receive(name: nil, app: "Mail", into: fixture.folder.path))
    // The folder the files were to be written to, not the app's name.
    #expect(
        state.errors == [
            FileOperationError(reason: .unreachable, path: dropFolder.path, errno: ETIMEDOUT)
        ])
}

@MainActor @Test func aDropFolderThatCantBeReadFailsTheDropNamingTheFolder() async throws {
    let fixture = try await Fixture()
    defer { fixture.stop() }
    let clock = ManualClock()
    let finished = await startDrop([StubPromise("never.jpg", .hangs)], fixture, clock: clock)
    let dropFolder = try fixture.dropFolder()
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o000], ofItemAtPath: dropFolder.path)
    defer {
        _ = try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: dropFolder.path)
    }

    clock.advance(by: FilePromiseReceiver.progressInterval)
    guard await waitForTheDrop(finished, "the unreadable folder didn't end it") else { return }

    await settle { !fixture.reportedFailures.isEmpty }
    let (_, state) = try #require(fixture.reportedFailures.first)
    #expect(
        state.errors.first
            == FileOperationError(reason: .permissionDenied, path: dropFolder.path, errno: EACCES))
    #expect(!state.errors.contains { $0.reason == .unreachable })
}

@MainActor @Test func aFileStillGrowingIsWaitedForPastTheIdleTimeout() async throws {
    let fixture = try await Fixture()
    defer { fixture.stop() }
    let clock = ManualClock()
    let promise = GrowingPromise("big.mov")
    let finished = await startDrop([promise], fixture, clock: clock)
    #expect(promise.isCalledIn)

    for _ in 0..<(readsToTimeOut * 3) {
        try promise.grow()
        await nextRead(clock)
    }
    #expect(!finished.value)
    try promise.finish()
    guard await waitForTheDrop(finished, "the finished file didn't end it") else { return }

    let size =
        try FileManager.default.attributesOfItem(
            atPath: fixture.folder.appending(path: "big.mov").path)[.size] as? Int
    #expect(size == readsToTimeOut * 3 * 1024)
    #expect(fixture.reportedFailures.isEmpty)
}

@MainActor @Test func aFileThatStopsGrowingTimesOut() async throws {
    let fixture = try await Fixture()
    defer { fixture.stop() }
    let clock = ManualClock()
    let promise = GrowingPromise("big.mov")
    let finished = await startDrop([promise], fixture, clock: clock)

    for _ in 0..<3 {
        try promise.grow()
        await nextRead(clock)
    }
    for _ in 1..<readsToTimeOut { await nextRead(clock) }
    #expect(!finished.value)
    try promise.abandon()
    clock.advance(by: FilePromiseReceiver.progressInterval)
    guard await waitForTheDrop(finished, "the idle timeout didn't end it") else { return }

    #expect(try fixture.contents(of: fixture.folder) == ["a.txt", "sub"])
    await settle { !fixture.reportedFailures.isEmpty }
    #expect(fixture.reportedFailures.first?.1.errors.map(\.reason) == [.unreachable])
}

@MainActor @Test func promisedFilesDroppedOnAFolderRowLandInIt() async throws {
    let fixture = try await Fixture()
    defer { fixture.stop() }
    let sub = fixture.folder.appending(path: "sub")

    await FilePromiseReceiver.receive(
        [StubPromise("photo.jpg")], into: sub.path, from: nil, selectingIn: nil,
        queue: fixture.queue)

    #expect(try fixture.contents(of: sub) == ["photo.jpg"])
}

// MARK: Dropping at a server

/// A drop at a server pane, whose rows are its shares `main` and `music`, refuses the pane's
/// background, as a server has no folder to put the files in, and takes a share's row as any
/// folder's, into its mount point (0114-server-location.md). Nothing lists a server yet, so the
/// pane is made with its rows; nothing is dropped, only validated, since a share's mount point
/// is in /Volumes.
@MainActor @Test func aDropAtAServerIsRefusedOnTheBackgroundAndTakenOnAShare() async throws {
    let server = try #require(Server(host: "HAL9000._smb._tcp.local"))
    let rows = await Task.detached { Listing([folder("main"), folder("music")]) }.value
    let pane = Pane(
        location: .server(server), service: ListingService(), systemActions: StubSystemActions(),
        settings: untouchedSettings(), sortedBy: .name, ascending: true, isFocused: true,
        selection: Selection(), viewMode: .list, rows: rows)
    let controller = PaneViewController(
        pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
        tableView: ListingTableView(), monitorsFolders: false)
    controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    let list = controller.listingViewController
    let mounts = MountTable(read: {
        [VolumeIdentity(device: "/dev/disk3s1", mountPoint: "/", kind: .local)]
    })
    await settle { mounts.isRead }
    list.fileOperations = FileOperationQueue(prompts: .unexpected) { _ in }
    list.mountTable = mounts
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("searcher-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let item = NSPasteboardItem()
    item.setString(URL(fileURLWithPath: "/Users/someone/a.txt").absoluteString, forType: .fileURL)
    #expect(pasteboard.writeObjects([item]))
    let info = StubDraggingInfo(pasteboard: pasteboard, mask: noKeys)
    func validate(row: Int, _ operation: NSTableView.DropOperation) -> NSDragOperation {
        list.tableView(
            list.tableView, validateDrop: info, proposedRow: row, proposedDropOperation: operation)
    }
    let music = try #require(rows.row(named: "music"))

    #expect(validate(row: -1, .on) == [])
    #expect(validate(row: 1, .above) == [])
    #expect(!list.tableView(list.tableView, acceptDrop: info, row: -1, dropOperation: .on))
    #expect(validate(row: music, .on) == .move)
}

// MARK: Dragging from the list

@MainActor @Test func aRowDragsAsItsFileURLAFoldersWithASlash() async throws {
    let fixture = try await Fixture()
    defer { fixture.stop() }

    let file = fixture.list.tableView(
        fixture.table, pasteboardWriterForRow: try fixture.row("a.txt"))
    let folder = fixture.list.tableView(
        fixture.table, pasteboardWriterForRow: try fixture.row("sub"))

    #expect(
        (file as? NSPasteboardItem)?.string(forType: .fileURL)
            == fixture.folder.appending(path: "a.txt").absoluteString)
    #expect(
        (folder as? NSPasteboardItem)?.string(forType: .fileURL)
            == fixture.folder.appending(path: "sub", directoryHint: .isDirectory).absoluteString)
}
