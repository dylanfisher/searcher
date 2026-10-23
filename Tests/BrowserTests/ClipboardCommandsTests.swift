import Base
import Foundation
import TestSupport
import Testing

@testable import Browser

private let copy = KeyChord("c", modifiers: .command)
private let cut = KeyChord("x", modifiers: .command)
private let paste = KeyChord("v", modifiers: .command)
private let moveHere = KeyChord("v", modifiers: [.command, .option])

/// Long enough for a command that wrongly went ahead to have queued its operation and finished it.
private let settleTime: Duration = .milliseconds(300)

/// A clipboard in memory. `otherAppWrites` stands for any write Searcher didn't make.
@MainActor
private final class MemoryClipboard: FileClipboard {
    private(set) var changeCount = 0
    private var urls: [URL] = []

    func write(_ urls: [URL]) {
        self.urls = urls
        changeCount += 1
    }

    func fileURLs() -> [URL] { urls }

    func otherAppWrites(_ urls: [URL] = []) {
        write(urls)
    }
}

/// A window of one tab over a real folder, with a queue whose questions `prompter` answers and a
/// clipboard that other windows can share.
@MainActor
private final class Window {
    let workspace: Workspace
    let prompter = Prompter()
    let queue: FileOperationQueue
    let clipboard: CutState
    /// Every snapshot the queue sent.
    let snapshots = EventLog<[FileOperationQueue.Snapshot]>()
    private(set) var nameEdits = 0

    init(at path: String, clipboard: CutState = CutState(clipboard: MemoryClipboard())) async {
        let pane = Pane(
            location: Location(path: path), service: ListingService(),
            systemActions: StubSystemActions(), settings: untouchedSettings())
        workspace = Workspace(tab: Tab(pane: pane))
        self.clipboard = clipboard
        queue = FileOperationQueue(
            fileSystem: .real, prompts: prompter.prompts, clock: ContinuousClock()
        ) { [snapshots] in snapshots.append($0) }
        await settle { pane.state.isLoaded }
    }

    var pane: Pane { workspace.selectedTab.focusedPane.commandPane }

    func context(withQueue: Bool = true, withClipboard: Bool = true) -> CommandContext {
        CommandContext(
            pane: pane, workspace: workspace, fileOperations: withQueue ? queue : nil,
            editName: { self.nameEdits += 1 }, clipboard: withClipboard ? clipboard : nil)
    }

    func binding(for chord: KeyChord) throws -> CommandBinding {
        var registry = CommandRegistry()
        for binding in ClipboardCommands.bindings {
            try registry.register(binding.command)
        }
        let command = try #require(registry.command(for: chord), "nothing is bound to \(chord)")
        return try #require(ClipboardCommands.bindings.first { $0.command == command })
    }

    func press(_ chord: KeyChord) throws {
        try binding(for: chord).run(context())
    }

    func isEnabled(_ chord: KeyChord, withQueue: Bool = true, withClipboard: Bool = true) throws
        -> Bool
    {
        try binding(for: chord).isEnabled?(
            context(withQueue: withQueue, withClipboard: withClipboard)) ?? true
    }

    /// The last state the queue reported for each operation, in the order queued.
    var finished: [(FileOperation, OperationState)] {
        var last: [FileOperationQueue.ID: FileOperationQueue.Snapshot] = [:]
        for snapshot in snapshots.all.joined() {
            last[snapshot.id] = snapshot
        }
        return last.values.sorted { $0.id < $1.id }.filter { $0.state.phase.isFinished }
            .map { ($0.operation, $0.state) }
    }

    func select(_ names: String...) {
        pane.select(
            Selection(Set(names.map(ExactName.init)), cursor: names.last.map(ExactName.init)))
    }
}

/// Watches `pane`'s folder and applies what changes there to the pane, as the window does.
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

private func names(in folder: String) throws -> Set<String> {
    Set(try FileManager.default.contentsOfDirectory(atPath: folder))
}

// MARK: Chords

@Test func eachClipboardChordInTheKeyTableResolvesToItsCommand() throws {
    var registry = CommandRegistry()
    for binding in ClipboardCommands.bindings {
        try registry.register(binding.command)
    }
    let expected: [(KeyChord, Command)] = [
        (copy, ClipboardCommands.copy),
        (cut, ClipboardCommands.cut),
        (paste, ClipboardCommands.paste),
        (moveHere, ClipboardCommands.moveHere),
    ]

    for (chord, command) in expected {
        #expect(registry.command(for: chord) == command, "\(chord)")
    }
    #expect(ClipboardCommands.bindings.count == expected.count)
}

// MARK: Copy and cut

@MainActor @Test func copyPutsTheSelectedFilesURLsOnTheClipboard() async throws {
    let folder = try TemporaryFolder("ClipboardCommandsTests")
    try write("a.txt", "b.txt", "c.txt", in: folder.url.path)
    let window = await Window(at: folder.url.path)
    window.select("a.txt", "c.txt")

    try window.press(copy)

    #expect(
        Set(window.clipboard.clipboard.fileURLs().map(\.path)) == [
            folder.url.path + "/a.txt", folder.url.path + "/c.txt",
        ])
    #expect(window.clipboard.cutNames(in: window.pane.location).isEmpty)
}

/// Finder writes a folder's file URL with a trailing slash. Whether an entry is a folder comes
/// from the listing, so building its URL reads nothing from the disk.
@MainActor @Test func aCopiedFoldersURLEndsInASlash() async throws {
    let folder = try TemporaryFolder("ClipboardCommandsTests")
    try write("a.txt", in: folder.url.path)
    try FileManager.default.createDirectory(
        atPath: folder.url.path + "/docs", withIntermediateDirectories: false)
    let window = await Window(at: folder.url.path)
    window.select("a.txt", "docs")

    try window.press(copy)

    #expect(
        Set(window.clipboard.clipboard.fileURLs().map(\.absoluteString)) == [
            URL(fileURLWithPath: folder.url.path + "/a.txt", isDirectory: false).absoluteString,
            URL(fileURLWithPath: folder.url.path + "/docs/", isDirectory: true).absoluteString,
        ])
    try window.press(cut)
    #expect(window.clipboard.cutNames(in: window.pane.location) == ["a.txt", "docs"])
}

@MainActor @Test func cutMarksTheSelectedFilesAsCutUntilTheClipboardChanges() async throws {
    let folder = try TemporaryFolder("ClipboardCommandsTests")
    try write("a.txt", "b.txt", in: folder.url.path)
    let window = await Window(at: folder.url.path)
    window.select("a.txt")

    try window.press(cut)

    #expect(window.clipboard.clipboard.fileURLs().map(\.path) == [folder.url.path + "/a.txt"])
    #expect(window.clipboard.cutNames(in: window.pane.location) == ["a.txt"])
    try #require(window.clipboard.clipboard as? MemoryClipboard).otherAppWrites()
    #expect(window.clipboard.cutNames(in: window.pane.location).isEmpty)
}

@MainActor @Test func aCopyAfterACutEndsTheCut() async throws {
    let folder = try TemporaryFolder("ClipboardCommandsTests")
    try write("a.txt", in: folder.url.path)
    let window = await Window(at: folder.url.path)
    window.select("a.txt")
    var changes = 0
    window.clipboard.observe(for: window) { changes += 1 }

    try window.press(cut)
    try window.press(copy)

    #expect(window.clipboard.cutNames(in: window.pane.location).isEmpty)
    #expect(changes == 2)
}

// MARK: Paste

@MainActor @Test func cutThenPasteInAnotherFolderMovesTheFilesAndClearsTheCut() async throws {
    let source = try TemporaryFolder("ClipboardCommandsTests")
    let destination = try TemporaryFolder("ClipboardCommandsTests")
    try write("a.txt", "b.txt", "c.txt", in: source.url.path)
    let from = await Window(at: source.url.path)
    let to = await Window(at: destination.url.path, clipboard: from.clipboard)
    from.select("a.txt", "b.txt")

    try from.press(cut)
    try to.press(paste)

    await settle {
        exists(destination.url.path + "/a.txt") && exists(destination.url.path + "/b.txt")
    }
    #expect(try names(in: source.url.path) == ["c.txt"])
    #expect(from.clipboard.cutNames(in: from.pane.location).isEmpty)
    #expect(to.prompter.confirms.all.isEmpty)
}

/// The first Cmd-V moves the cut files and ends the cut, so the second one copies the same
/// sources while the move runs or after it: the queue refuses it, or it fails with the
/// sources gone. Either way it is reported, and nothing is copied.
@MainActor @Test func aSecondPasteAfterACutIsRefusedOrFailsAndCopiesNothing() async throws {
    let source = try TemporaryFolder("ClipboardCommandsTests")
    let destination = try TemporaryFolder("ClipboardCommandsTests")
    try write("a.txt", "b.txt", in: source.url.path)
    let from = await Window(at: source.url.path)
    let to = await Window(at: destination.url.path, clipboard: from.clipboard)
    from.select("a.txt", "b.txt")

    try from.press(cut)
    try to.press(paste)
    try to.press(paste)

    await settle { to.finished.count == 2 }
    let finished = to.finished
    try #require(finished.count == 2)
    #expect(
        finished[0].0
            == .move(
                [source.url.path + "/a.txt", source.url.path + "/b.txt"], into: destination.url.path
            ))
    #expect(finished[0].1.phase == .done)
    #expect(
        finished[1].0
            == .copy(
                [source.url.path + "/a.txt", source.url.path + "/b.txt"], into: destination.url.path
            ))
    switch finished[1].1.phase {
    case .refused: break
    case .failed: #expect(finished[1].1.errors.count == 2)
    default: Issue.record("the second paste ended \(finished[1].1.phase)")
    }
    #expect(try names(in: destination.url.path) == ["a.txt", "b.txt"])
    #expect(try names(in: source.url.path).isEmpty)
}

@MainActor @Test func afterACutAnyOtherClipboardWriteMakesPasteCopy() async throws {
    let source = try TemporaryFolder("ClipboardCommandsTests")
    let destination = try TemporaryFolder("ClipboardCommandsTests")
    try write("a.txt", in: source.url.path)
    let from = await Window(at: source.url.path)
    let to = await Window(at: destination.url.path, clipboard: from.clipboard)
    from.select("a.txt")

    try from.press(cut)
    // Another app puts the same file on the clipboard, as Finder's Copy would.
    try #require(from.clipboard.clipboard as? MemoryClipboard).otherAppWrites([
        URL(fileURLWithPath: source.url.path + "/a.txt")
    ])
    try to.press(paste)

    await settle { exists(destination.url.path + "/a.txt") }
    #expect(exists(source.url.path + "/a.txt"))
}

@MainActor @Test func copyThenPasteCopiesAndAsksNothing() async throws {
    let source = try TemporaryFolder("ClipboardCommandsTests")
    let destination = try TemporaryFolder("ClipboardCommandsTests")
    try write("a.txt", in: source.url.path)
    let from = await Window(at: source.url.path)
    let to = await Window(at: destination.url.path, clipboard: from.clipboard)
    from.select("a.txt")

    try from.press(copy)
    try to.press(paste)

    await settle { exists(destination.url.path + "/a.txt") }
    #expect(exists(source.url.path + "/a.txt"))
    try await Task.sleep(for: settleTime)
    #expect(to.prompter.confirms.all.isEmpty)
}

@MainActor @Test func moveHereAfterACopyMovesAndAsksNothing() async throws {
    let source = try TemporaryFolder("ClipboardCommandsTests")
    let destination = try TemporaryFolder("ClipboardCommandsTests")
    try write("a.txt", in: source.url.path)
    let from = await Window(at: source.url.path)
    let to = await Window(at: destination.url.path, clipboard: from.clipboard)
    from.select("a.txt")

    try from.press(copy)
    try to.press(moveHere)

    await settle { exists(destination.url.path + "/a.txt") }
    #expect(!exists(source.url.path + "/a.txt"))
    #expect(to.prompter.confirms.all.isEmpty)
}

@MainActor @Test func filesAnotherAppPutOnTheClipboardPasteAsACopy() async throws {
    let source = try TemporaryFolder("ClipboardCommandsTests")
    let destination = try TemporaryFolder("ClipboardCommandsTests")
    try write("a.txt", "b.txt", in: source.url.path)
    let window = await Window(at: destination.url.path)
    try #require(window.clipboard.clipboard as? MemoryClipboard).otherAppWrites([
        URL(fileURLWithPath: source.url.path + "/a.txt"),
        URL(fileURLWithPath: source.url.path + "/b.txt"),
    ])

    #expect(try window.isEnabled(paste))
    try window.press(paste)

    await settle {
        exists(destination.url.path + "/a.txt") && exists(destination.url.path + "/b.txt")
    }
    #expect(try names(in: source.url.path) == ["a.txt", "b.txt"])
}

@MainActor @Test func aCopyPastedIntoItsOwnFolderMakesDuplicateNamedCopies() async throws {
    let folder = try TemporaryFolder("ClipboardCommandsTests")
    try write("a.txt", in: folder.url.path)
    let window = await Window(at: folder.url.path)
    window.select("a.txt")

    try window.press(copy)
    try window.press(paste)

    await settle { exists(folder.url.path + "/a copy.txt") }
    #expect(try names(in: folder.url.path) == ["a.txt", "a copy.txt"])
}

@MainActor @Test func aCutPastedIntoItsOwnFolderDoesNothing() async throws {
    let folder = try TemporaryFolder("ClipboardCommandsTests")
    try write("a.txt", in: folder.url.path)
    let window = await Window(at: folder.url.path)
    window.select("a.txt")

    try window.press(cut)
    try window.press(paste)
    try await Task.sleep(for: settleTime)

    #expect(try names(in: folder.url.path) == ["a.txt"])
    #expect(window.prompter.conflicts.all.isEmpty)
}

@MainActor @Test func pastedItemsAreSelectedOnceListedAndNoNameIsEdited() async throws {
    let source = try TemporaryFolder("ClipboardCommandsTests")
    let destination = try TemporaryFolder("ClipboardCommandsTests")
    try write("a.txt", "b.txt", in: source.url.path)
    try write("z.txt", in: destination.url.path)
    let from = await Window(at: source.url.path)
    let to = await Window(at: destination.url.path, clipboard: from.clipboard)
    let monitor = try await watch(to.pane)
    defer { monitor.stop() }
    from.select("a.txt", "b.txt")
    to.select("z.txt")

    try from.press(copy)
    try to.press(paste)

    await settle { selectedNames(to.pane) == ["a.txt", "b.txt"] }
    try await Task.sleep(for: settleTime)
    #expect(to.nameEdits == 0)
}

// MARK: Enabled

@MainActor @Test func copyAndCutAreOffWithNothingSelectedOrNoClipboard() async throws {
    let folder = try TemporaryFolder("ClipboardCommandsTests")
    try write("a.txt", in: folder.url.path)
    let window = await Window(at: folder.url.path)

    #expect(try !window.isEnabled(copy))
    #expect(try !window.isEnabled(cut))
    try window.press(copy)
    #expect(window.clipboard.clipboard.fileURLs().isEmpty)

    window.select("a.txt")
    #expect(try window.isEnabled(copy))
    #expect(try window.isEnabled(cut))
    #expect(try !window.isEnabled(copy, withClipboard: false))
    #expect(try !window.isEnabled(cut, withClipboard: false))
}

@MainActor @Test func pasteIsOffWithNoFilesOnTheClipboardOrNoQueue() async throws {
    let folder = try TemporaryFolder("ClipboardCommandsTests")
    try write("a.txt", in: folder.url.path)
    let window = await Window(at: folder.url.path)

    #expect(try !window.isEnabled(paste))
    #expect(try !window.isEnabled(moveHere))

    window.select("a.txt")
    try window.press(copy)
    #expect(try window.isEnabled(paste))
    #expect(try window.isEnabled(moveHere))
    #expect(try !window.isEnabled(paste, withQueue: false))
    #expect(try !window.isEnabled(moveHere, withQueue: false))
    #expect(try !window.isEnabled(paste, withClipboard: false))
}
