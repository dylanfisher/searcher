import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser

private let bounds = Rect(x: 0, y: 0, width: 1200, height: 800)

private let trash = KeyChord(.delete, modifiers: .command)
private let newFolder = KeyChord("n", modifiers: [.command, .shift])
private let duplicate = KeyChord("d", modifiers: .command)
private let rename = KeyChord(.return)
private let copyToOtherPane = KeyChord("c", modifiers: [.command, .shift])
private let moveToOtherPane = KeyChord("m", modifiers: [.command, .shift])

/// Long enough for a command that wrongly went ahead to have queued its operation and finished it.
private let settleTime: Duration = .milliseconds(300)

/// A window of one tab over a real folder, with a queue whose questions `prompter` answers.
@MainActor
private final class Window {
    let workspace: Workspace
    let prompter = Prompter()
    let queue: FileOperationQueue
    private(set) var nameEdits = 0

    /// The queue works on `fileSystem`, the real one unless a test holds a call.
    init(at path: String, fileSystem: FileOperationQueue.FileSystem = .real) async {
        let pane = Pane(
            location: Location(path: path), service: ListingService(),
            systemActions: StubSystemActions(), settings: untouchedSettings())
        workspace = Workspace(tab: Tab(pane: pane))
        queue = FileOperationQueue(
            fileSystem: fileSystem, prompts: prompter.prompts, clock: ContinuousClock()
        ) { _ in }
        await settle { pane.state.isLoaded }
    }

    var tab: Tab { workspace.selectedTab }
    var pane: Pane { tab.focusedPane.commandPane }

    /// Splits right, shows `path` in the new pane once it is listed, and focuses the first pane
    /// again, so the new pane is the other pane. Returns it.
    func splitRight(showing path: String) async throws -> Pane {
        let first = tab.layout.focused
        let other = try #require(tab.split(.horizontal, in: bounds))
        other.navigate(to: Location(path: path))
        await settle { other.state.isLoaded }
        tab.focus(first)
        return other
    }

    func context(withQueue: Bool = true) -> CommandContext {
        CommandContext(
            pane: pane, workspace: workspace, tabBounds: { bounds },
            fileOperations: withQueue ? queue : nil, editName: { self.nameEdits += 1 })
    }

    func binding(for chord: KeyChord) throws -> CommandBinding {
        var registry = CommandRegistry()
        for binding in FileCommands.bindings {
            try registry.register(binding.command)
        }
        let command = try #require(registry.command(for: chord), "nothing is bound to \(chord)")
        return try #require(FileCommands.bindings.first { $0.command == command })
    }

    func press(_ chord: KeyChord) throws {
        try binding(for: chord).run(context())
    }

    func isEnabled(_ chord: KeyChord, withQueue: Bool = true) throws -> Bool {
        try binding(for: chord).isEnabled?(context(withQueue: withQueue)) ?? true
    }

    func select(_ names: String...) {
        pane.select(
            Selection(Set(names.map(ExactName.init)), cursor: names.last.map(ExactName.init)))
    }

    /// Switches the window's pane to column mode, selects the folder `name` in its focused
    /// column, as a click does, and returns the pane of the column that opens for it, listed.
    func showColumns(selectingFolder name: String) async throws -> Pane {
        let owner = workspace.selectedTab.focusedPane
        owner.setViewMode(.column)
        let trail = try #require(owner.columnTrail)
        await settle { trail.focused.pane.state.isLoaded }
        select(name)
        await settle {
            trail.columns.count == trail.focusedIndex + 2
                && trail.columns.last?.pane.location.name == name
                && trail.columns.last?.pane.state.isLoaded == true
        }
        return try #require(trail.columns.last?.pane)
    }
}

/// Watches `pane`'s folder and applies what changes there to the pane, as the window does. The
/// pane stops the monitor when it leaves the folder; the test stops it at the end.
@MainActor
private func watch(_ pane: Pane) async throws -> FolderMonitor {
    let location = pane.location
    let monitor = try await BlockingCallThread.run { [weak pane] in
        try FolderMonitor(location: location) { [weak pane] change in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { pane?.apply(change, at: location) }
            }
        }
    }
    pane.monitor = monitor
    return monitor
}

/// The names selected one by one; empty while the selection isn't settled or after Select All.
@MainActor
private func selectedNames(_ pane: Pane) -> Set<String> {
    guard pane.selection.isSettled, case .only(let names) = pane.selection.members else {
        return []
    }
    return Set(names.map(\.name))
}

private func write(_ names: String..., in folder: String) throws {
    for name in names {
        try Data(name.utf8).write(to: URL(fileURLWithPath: folder + "/" + name))
    }
}

private func exists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
}

// MARK: Chords

@Test func eachFileChordInTheKeyTableResolvesToItsCommand() throws {
    var registry = CommandRegistry()
    for binding in FileCommands.bindings {
        try registry.register(binding.command)
    }
    let expected: [(KeyChord, Command)] = [
        (trash, FileCommands.moveToTrash),
        (newFolder, FileCommands.newFolder),
        (duplicate, FileCommands.duplicate),
        (rename, FileCommands.rename),
        (copyToOtherPane, FileCommands.copyToOtherPane),
        (moveToOtherPane, FileCommands.moveToOtherPane),
    ]

    for (chord, command) in expected {
        #expect(registry.command(for: chord) == command, "\(chord)")
    }
    #expect(FileCommands.bindings.count == expected.count)
}

// MARK: Commander F-key preset

private let f5 = KeyChord(.function(5))
private let f6 = KeyChord(.function(6))
private let f7 = KeyChord(.function(7))
private let f8 = KeyChord(.function(8))

@Test func withTheCommanderPresetF5ToF8ResolveToTheirFileCommands() throws {
    let registry = try KeyBindings(
        commands: AppCommands.commands, preset: FileCommands.commanderFKeys
    ).registry
    let expected: [(KeyChord, CommandID)] = [
        (f5, FileCommands.copyToOtherPane.id),
        (f6, FileCommands.moveToOtherPane.id),
        (f7, FileCommands.newFolder.id),
        (f8, FileCommands.moveToTrash.id),
        (copyToOtherPane, FileCommands.copyToOtherPane.id),
        (moveToOtherPane, FileCommands.moveToOtherPane.id),
    ]

    for (chord, id) in expected {
        #expect(registry.command(for: chord)?.id == id, "\(chord)")
    }
    // The menu shows the first chord, so it stays the Command one.
    #expect(registry.command(for: f5)?.chords.first == copyToOtherPane)
}

@Test func withoutTheCommanderPresetF5ToF8AreUnboundAndCmdShiftCAndMStayBound() throws {
    let registry = try AppCommands.registry()

    for chord in [f5, f6, f7, f8] {
        #expect(registry.command(for: chord) == nil, "\(chord)")
    }
    #expect(registry.command(for: copyToOtherPane)?.id == FileCommands.copyToOtherPane.id)
    #expect(registry.command(for: moveToOtherPane)?.id == FileCommands.moveToOtherPane.id)
}

@MainActor @Test func f5AsksBeforeCopyingToTheOtherPaneAsCmdShiftCDoes() async throws {
    let source = try TemporaryFolder("FileCommandsTests")
    let destination = try TemporaryFolder("FileCommandsTests")
    try write("a.txt", in: source.url.path)
    let window = await Window(at: source.url.path)
    _ = try await window.splitRight(showing: destination.url.path)
    window.select("a.txt")
    let id = try #require(
        try KeyBindings(commands: AppCommands.commands, preset: FileCommands.commanderFKeys)
            .registry.command(for: f5)?.id)
    let binding = try #require(FileCommands.bindings.first { $0.command.id == id })

    binding.run(window.context())

    #expect(await window.prompter.confirms.wait { $0.count == 1 })
    #expect(
        window.prompter.confirms.all == [
            .otherPane(.copy([source.url.path + "/a.txt"], into: destination.url.path))
        ])
    window.prompter.answer(confirming: false)
}

// MARK: Copy and move to the other pane

@MainActor @Test func copyToOtherPaneAsksNamingTheOtherPanesFolderAndCopiesOnlyOnceConfirmed()
    async throws
{
    let source = try TemporaryFolder("FileCommandsTests")
    let destination = try TemporaryFolder("FileCommandsTests")
    try write("a.txt", "b.txt", in: source.url.path)
    let window = await Window(at: source.url.path)
    _ = try await window.splitRight(showing: destination.url.path)
    window.select("a.txt")

    try window.press(copyToOtherPane)

    #expect(await window.prompter.confirms.wait { $0.count == 1 })
    #expect(
        window.prompter.confirms.all == [
            .otherPane(.copy([source.url.path + "/a.txt"], into: destination.url.path))
        ])
    try await Task.sleep(for: settleTime)
    #expect(!exists(destination.url.path + "/a.txt"))

    window.prompter.answer(confirming: true)

    await settle { exists(destination.url.path + "/a.txt") }
    #expect(exists(source.url.path + "/a.txt"))
    #expect(!exists(destination.url.path + "/b.txt"))
}

@MainActor @Test func moveToOtherPaneAnsweredNoMovesNothing() async throws {
    let source = try TemporaryFolder("FileCommandsTests")
    let destination = try TemporaryFolder("FileCommandsTests")
    try write("a.txt", in: source.url.path)
    let window = await Window(at: source.url.path)
    _ = try await window.splitRight(showing: destination.url.path)
    window.select("a.txt")

    try window.press(moveToOtherPane)
    #expect(await window.prompter.confirms.wait { $0.count == 1 })
    #expect(
        window.prompter.confirms.all == [
            .otherPane(.move([source.url.path + "/a.txt"], into: destination.url.path))
        ])
    window.prompter.answer(confirming: false)
    try await Task.sleep(for: settleTime)

    #expect(exists(source.url.path + "/a.txt"))
    #expect(!exists(destination.url.path + "/a.txt"))
}

@MainActor @Test func moveToOtherPaneConfirmedMovesTheSelection() async throws {
    let source = try TemporaryFolder("FileCommandsTests")
    let destination = try TemporaryFolder("FileCommandsTests")
    try write("a.txt", "b.txt", in: source.url.path)
    let window = await Window(at: source.url.path)
    _ = try await window.splitRight(showing: destination.url.path)
    window.select("a.txt", "b.txt")

    try window.press(moveToOtherPane)
    window.prompter.answer(confirming: true)

    await settle {
        exists(destination.url.path + "/a.txt") && exists(destination.url.path + "/b.txt")
    }
    #expect(!exists(source.url.path + "/a.txt"))
}

@MainActor @Test func copyAndMoveToOtherPaneAreOffWithOnePaneAndDoNothing() async throws {
    let source = try TemporaryFolder("FileCommandsTests")
    try write("a.txt", in: source.url.path)
    let window = await Window(at: source.url.path)
    window.select("a.txt")

    #expect(try !window.isEnabled(copyToOtherPane))
    #expect(try !window.isEnabled(moveToOtherPane))
    try window.press(copyToOtherPane)
    try window.press(moveToOtherPane)
    try await Task.sleep(for: settleTime)

    #expect(window.prompter.confirms.all.isEmpty)
    #expect(window.tab.layout.panes.count == 1)
}

// MARK: New folder and duplicate

@MainActor @Test func newFolderSelectsTheNewFolderOnceItAppears() async throws {
    let folder = try TemporaryFolder("FileCommandsTests")
    try write("a.txt", in: folder.url.path)
    let window = await Window(at: folder.url.path)
    let monitor = try await watch(window.pane)
    defer { monitor.stop() }
    window.select("a.txt")

    try window.press(newFolder)

    await settle { selectedNames(window.pane) == ["untitled folder"] }
    #expect(window.pane.selection.cursor == ExactName("untitled folder"))
    #expect(window.pane.state.listing?.row(named: "untitled folder") != nil)
    await settle { window.nameEdits == 1 }
}

/// In column view, with a folder selected in the focused column and its column shown, New Folder
/// makes the folder inside it, as Finder's does, selects it there with the keys moved into that
/// column, and edits its name.
@MainActor @Test func newFolderInColumnViewMakesTheFolderInTheSelectedFolder() async throws {
    let folder = try TemporaryFolder("FileCommandsTests")
    try write("a.txt", in: folder.url.path)
    try FileManager.default.createDirectory(
        atPath: folder.url.path + "/_test", withIntermediateDirectories: false)
    let window = await Window(at: folder.url.path)
    let inner = try await window.showColumns(selectingFolder: "_test")
    let monitor = try await watch(inner)
    defer { monitor.stop() }

    try window.press(newFolder)

    await settle { selectedNames(inner) == ["untitled folder"] }
    #expect(exists(folder.url.path + "/_test/untitled folder"))
    #expect(!exists(folder.url.path + "/untitled folder"))
    #expect(window.pane === inner)
    #expect(window.nameEdits == 1)
}

/// The folder is read when New Folder runs: selecting a file while it runs closes the folder's
/// column, which drops the name waiting there, so nothing is selected or edited.
@MainActor @Test func aSelectionMadeWhileNewFolderRunsDoesntMoveItsFolder() async throws {
    let folder = try TemporaryFolder("FileCommandsTests")
    try write("a.txt", in: folder.url.path)
    try FileManager.default.createDirectory(
        atPath: folder.url.path + "/_test", withIntermediateDirectories: false)
    let window = await Window(at: folder.url.path)
    _ = try await window.showColumns(selectingFolder: "_test")
    let trail = try #require(window.tab.focusedPane.columnTrail)
    let focused = window.pane

    try window.press(newFolder)
    window.select("a.txt")

    await settle { exists(folder.url.path + "/_test/untitled folder") }
    #expect(!exists(folder.url.path + "/untitled folder"))
    #expect(!trail.columns.contains { $0.pane.location.name == "_test" })
    #expect(window.pane === focused)
    #expect(selectedNames(focused) == ["a.txt"])
    #expect(window.nameEdits == 0)
}

/// New Folder's names wait in the pane with a closure that holds the command's context, which
/// holds the pane; closing the pane drops them, so it is released.
@MainActor @Test func aPaneClosedWithNewFolderNamesPendingIsReleased() async throws {
    let folder = try TemporaryFolder("FileCommandsTests")
    weak var released: Pane?
    do {
        // No monitor, so the new folder is never listed and its name stays pending.
        let window = await Window(at: folder.url.path)
        released = window.pane
        try window.press(newFolder)
        await settle { exists(folder.url.path + "/untitled folder") }
        try await Task.sleep(for: settleTime)
        window.pane.close()
    }

    await settle { released == nil }
}

@MainActor @Test func aNewFolderThatFailsEditsNoName() async throws {
    let folder = try TemporaryFolder("FileCommandsTests")
    let window = await Window(at: folder.url.path)
    #expect(chmod(folder.url.path, 0o555) == 0)
    defer { chmod(folder.url.path, 0o755) }

    try window.press(newFolder)
    try await Task.sleep(for: settleTime)
    #expect(chmod(folder.url.path, 0o755) == 0)
    try write("new.txt", in: folder.url.path)
    window.pane.reload()
    await settle { window.pane.state.listing?.row(named: "new.txt") != nil }
    window.select("new.txt")

    try await Task.sleep(for: settleTime)
    #expect(window.nameEdits == 0)
}

@MainActor @Test func duplicateSelectsTheCopiesOnceTheyAppear() async throws {
    let folder = try TemporaryFolder("FileCommandsTests")
    try write("a.txt", "b.txt", in: folder.url.path)
    let window = await Window(at: folder.url.path)
    let monitor = try await watch(window.pane)
    defer { monitor.stop() }
    window.select("a.txt", "b.txt")

    try window.press(duplicate)

    await settle { selectedNames(window.pane) == ["a copy.txt", "b copy.txt"] }
    #expect(exists(folder.url.path + "/a.txt"))
}

@MainActor @Test func aSelectionMadeBeforeTheNewFolderAppearsIsKept() async throws {
    let folder = try TemporaryFolder("FileCommandsTests")
    try write("a.txt", "b.txt", in: folder.url.path)
    let window = await Window(at: folder.url.path)
    window.select("a.txt")

    try window.press(newFolder)
    await settle { exists(folder.url.path + "/untitled folder") }
    window.select("b.txt")
    try await Task.sleep(for: settleTime)
    window.pane.apply(.relist, at: window.pane.location)

    await settle { window.pane.state.listing?.row(named: "untitled folder") != nil }
    #expect(selectedNames(window.pane) == ["b.txt"])
}

/// Holds the queue's New Folder call until the test opens it, and logs when the call starts.
private final class NewFolderGate: @unchecked Sendable {
    let started = EventLog<String>()
    private let semaphore = DispatchSemaphore(value: 0)

    var fileSystem: FileOperationQueue.FileSystem {
        var fileSystem = FileOperationQueue.FileSystem.real
        let make = fileSystem.makeUntitledFolder
        fileSystem.makeUntitledFolder = { [self] folder throws(FileOperationError) in
            started.append(folder)
            semaphore.wait()
            return try make(folder)
        }
        return fileSystem
    }

    func open() {
        semaphore.signal()
    }
}

@MainActor @Test func aSelectionMadeWhileTheNewFolderIsBeingMadeIsKept() async throws {
    let folder = try TemporaryFolder("FileCommandsTests")
    try write("a.txt", "b.txt", in: folder.url.path)
    let gate = NewFolderGate()
    let window = await Window(at: folder.url.path, fileSystem: gate.fileSystem)
    window.select("a.txt")

    try window.press(newFolder)
    #expect(await gate.started.wait { $0.count == 1 })
    window.select("b.txt")
    gate.open()
    await settle { exists(folder.url.path + "/untitled folder") }
    try await Task.sleep(for: settleTime)
    window.pane.apply(.relist, at: window.pane.location)

    await settle { window.pane.state.listing?.row(named: "untitled folder") != nil }
    #expect(selectedNames(window.pane) == ["b.txt"])
}

@MainActor @Test func aFilterChangeDropsNamesWaitingToBeSelected() async throws {
    let folder = try TemporaryFolder("FileCommandsTests")
    try write("a.txt", in: folder.url.path)
    let window = await Window(at: folder.url.path)
    window.pane.setFilter("a")
    await settle { window.pane.state.listing?.count == 1 }
    window.select("a.txt")

    try window.press(newFolder)
    await settle { exists(folder.url.path + "/untitled folder") }
    try await Task.sleep(for: settleTime)
    window.pane.apply(.relist, at: window.pane.location)
    try await Task.sleep(for: settleTime)
    #expect(selectedNames(window.pane) == ["a.txt"])
    window.pane.setFilter("")

    await settle { window.pane.state.listing?.row(named: "untitled folder") != nil }
    try await Task.sleep(for: settleTime)
    #expect(selectedNames(window.pane) == ["a.txt"])
}

// MARK: Rename

@MainActor @Test func returnEditsTheNameOfTheOneSelectedEntry() async throws {
    let folder = try TemporaryFolder("FileCommandsTests")
    try write("a.txt", "b.txt", in: folder.url.path)
    let window = await Window(at: folder.url.path)
    window.select("a.txt")

    #expect(try window.isEnabled(rename))
    try window.press(rename)
    #expect(window.nameEdits == 1)

    window.select("a.txt", "b.txt")
    #expect(try !window.isEnabled(rename))
    try window.press(rename)
    #expect(window.nameEdits == 1)
}

@MainActor @Test func renameGoesThroughTheQueueAndTheSelectionFollowsTheNewName() async throws {
    let folder = try TemporaryFolder("FileCommandsTests")
    try write("a.txt", in: folder.url.path)
    let window = await Window(at: folder.url.path)
    let monitor = try await watch(window.pane)
    defer { monitor.stop() }
    window.select("a.txt")

    let state = await FileCommands.rename(
        "a.txt", to: "c.txt", in: window.pane, queue: window.queue)

    #expect(state.phase == .done)
    #expect(exists(folder.url.path + "/c.txt"))
    await settle { selectedNames(window.pane) == ["c.txt"] }
}

// MARK: Enabled

@MainActor @Test func commandsOnTheSelectionAreOffWithNothingSelected() async throws {
    let source = try TemporaryFolder("FileCommandsTests")
    let destination = try TemporaryFolder("FileCommandsTests")
    try write("a.txt", in: source.url.path)
    let window = await Window(at: source.url.path)
    _ = try await window.splitRight(showing: destination.url.path)

    for chord in [trash, duplicate, rename, copyToOtherPane, moveToOtherPane] {
        #expect(try !window.isEnabled(chord), "\(chord)")
    }
    #expect(try window.isEnabled(newFolder))
    try window.press(trash)
    try await Task.sleep(for: settleTime)
    #expect(exists(source.url.path + "/a.txt"))

    window.select("a.txt")
    for chord in [trash, duplicate, rename, copyToOtherPane, moveToOtherPane, newFolder] {
        #expect(try window.isEnabled(chord), "\(chord)")
    }
}

@MainActor @Test func everyFileCommandIsOffWithoutAQueue() async throws {
    let source = try TemporaryFolder("FileCommandsTests")
    let destination = try TemporaryFolder("FileCommandsTests")
    try write("a.txt", in: source.url.path)
    let window = await Window(at: source.url.path)
    _ = try await window.splitRight(showing: destination.url.path)
    window.select("a.txt")

    for chord in [trash, newFolder, duplicate, rename, copyToOtherPane, moveToOtherPane] {
        #expect(try !window.isEnabled(chord, withQueue: false), "\(chord)")
    }
}

// MARK: The cursor after a trash

/// The real file system, except that a trash leaves the item where it is. The test removes it
/// from the rows with a patch, as the folder monitor would once the item left.
private var keepingTrashedItems: FileOperationQueue.FileSystem {
    var fileSystem = FileOperationQueue.FileSystem.real
    fileSystem.trash = { path in URL(fileURLWithPath: "/stub-trash/" + path) }
    return fileSystem
}

/// A window over a folder of `a.txt` to `d.txt`, sorted by name, `ascending` or not.
@MainActor
private func fourFiles(ascending: Bool = true) async throws -> (Window, TemporaryFolder) {
    let folder = try TemporaryFolder("FileCommandsTests")
    try write("a.txt", "b.txt", "c.txt", "d.txt", in: folder.url.path)
    let window = await Window(at: folder.url.path, fileSystem: keepingTrashedItems)
    if !ascending {
        window.pane.setSort(.name, ascending: false)
        await settle { window.pane.state.listing?.ascending == false }
    }
    return (window, folder)
}

/// Removes `names` from the pane's rows, as the folder monitor reports a trash.
@MainActor
private func land(_ names: [String], in window: Window) async {
    let version = window.pane.stateVersion
    window.pane.apply(.patches(names.map { .remove(name: $0) }), at: window.pane.location)
    await settle { window.pane.stateVersion != version }
}

@MainActor
@Test(
    arguments: [
        // (sorted ascending, selected with the cursor on the last, rows trashed, now selected)
        (true, ["b.txt"], "c.txt"),
        (true, ["d.txt"], "c.txt"),
        (true, ["b.txt", "c.txt"], "d.txt"),
        (true, ["c.txt", "d.txt"], "b.txt"),
        (false, ["c.txt"], "b.txt"),
        (false, ["a.txt"], "b.txt"),
    ])
func aTrashedCursorRowHandsTheCursorToTheRowAfterItOnceItLeaves(
    ascending: Bool, trashed: [String], next: String
) async throws {
    let (window, folder) = try await fourFiles(ascending: ascending)
    defer { withExtendedLifetime(folder) {} }
    window.pane.select(
        Selection(Set(trashed.map(ExactName.init)), cursor: trashed.last.map(ExactName.init)))

    try window.press(trash)
    // Nothing moves on the press: the rows are still there.
    #expect(window.pane.selection.cursor == ExactName(trashed.last!))

    await land(trashed, in: window)

    #expect(window.pane.selection == Selection([ExactName(next)], cursor: ExactName(next)))
}

@MainActor @Test func aCursorMovedBeforeTheTrashLandsStaysWhereTheUserPutIt() async throws {
    let (window, folder) = try await fourFiles()
    defer { withExtendedLifetime(folder) {} }
    window.select("b.txt")
    try window.press(trash)

    window.select("a.txt")
    await land(["b.txt"], in: window)

    #expect(window.pane.selection == Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))
}

/// A click on another row and then on empty space before the trash lands empties the selection;
/// it stays empty when the trashed row leaves.
@MainActor @Test func aSelectionTheUserEmptiedBeforeTheTrashLandsStaysEmpty() async throws {
    let (window, folder) = try await fourFiles()
    defer { withExtendedLifetime(folder) {} }
    window.select("b.txt")
    try window.press(trash)

    window.select("c.txt")
    window.pane.select(Selection())
    await land(["b.txt"], in: window)

    #expect(window.pane.selection == Selection())
}

/// A trash that fails leaves nothing waiting, so the row leaving later for another reason, such
/// as another app deleting it, leaves no cursor.
@MainActor @Test func aFailedTrashLeavesNoCursorMoveForLater() async throws {
    let folder = try TemporaryFolder("FileCommandsTests")
    try write("a.txt", "b.txt", "c.txt", in: folder.url.path)
    var fileSystem = FileOperationQueue.FileSystem.real
    fileSystem.trash = { path throws(FileOperationError) in
        throw FileOperationError(errno: EACCES, path: path)
    }
    let window = await Window(at: folder.url.path, fileSystem: fileSystem)
    window.select("b.txt")

    try window.press(trash)
    await settle { window.pane.cursorAfterTrash == nil }
    await land(["b.txt"], in: window)

    #expect(window.pane.selection == Selection())
}

@MainActor @Test func aRowThatLeavesWithoutATrashLeavesNoCursor() async throws {
    let (window, folder) = try await fourFiles()
    defer { withExtendedLifetime(folder) {} }
    window.select("b.txt")

    await land(["b.txt"], in: window)

    #expect(window.pane.selection == Selection())
}

// MARK: Trash on a volume

/// Trashes only files the test makes on a disk image.
@MainActor @Suite(.serialized) struct FileCommandsDiskImageTests {
    @Test func threeTrashedFilesLeaveTheListingThroughTheMonitor() async throws {
        let image = try await DiskImage("FileCommandsTests")
        try write("a.txt", "b.txt", "c.txt", "d.txt", in: image.mountPoint)
        let window = await Window(at: image.mountPoint)
        let monitor = try await watch(window.pane)
        window.select("a.txt", "b.txt", "c.txt")

        try window.press(trash)

        await settle {
            let listing = window.pane.state.listing
            return ["a.txt", "b.txt", "c.txt"].allSatisfy { listing?.row(named: $0) == nil }
        }
        #expect(window.pane.state.listing?.row(named: "d.txt") != nil)
        #expect(window.prompter.confirms.all.isEmpty)
        monitor.stop()
        try await image.detach()
    }
}
