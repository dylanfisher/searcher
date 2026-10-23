import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser

/// Trashes only files the test makes on a disk image, so nothing reaches the user's Trash.
@MainActor @Suite(.serialized) struct OperationIntakeTests {
    /// Cmd-Z pressed in the same turn as Cmd-Delete undoes that trash, not the change before it.
    @Test func undoRightAfterATrashKeyUndoesThatTrash() async throws {
        let image = try await DiskImage("OperationIntakeTests")
        for name in ["earlier.txt", "pressed.txt"] {
            try Data(name.utf8).write(to: URL(fileURLWithPath: image.mountPoint + "/" + name))
        }
        let pane = Pane(
            location: Location(path: image.mountPoint), service: ListingService(),
            systemActions: StubSystemActions(), settings: untouchedSettings())
        let workspace = Workspace(tab: Tab(pane: pane))
        let history = UndoHistory(log: { _ in })
        let (finished, feed) = AsyncStream.makeStream(of: FileOperationQueue.Snapshot.self)
        history.follow(finished)
        let queue = FileOperationQueue(
            fileSystem: .real, prompts: Prompter().prompts, clock: ContinuousClock(),
            onChange: { _ in }, onAnyFinish: { feed.yield($0) })
        await settle { pane.state.isLoaded }
        _ = await queue.perform(.trash([image.mountPoint + "/earlier.txt"]))
        await history.catchUp(with: queue)
        pane.select(Selection([ExactName("pressed.txt")], cursor: ExactName("pressed.txt")))
        let context = CommandContext(pane: pane, workspace: workspace, fileOperations: queue)
        let trash = try #require(
            FileCommands.bindings.first { $0.command == FileCommands.moveToTrash })

        trash.run(context)
        let undo = history.undo(with: queue)
        let undone = try #require(await undo.value)

        #expect(
            undone.record.changes.compactMap(\.location) == [image.mountPoint + "/pressed.txt"])
        #expect(FileManager.default.fileExists(atPath: image.mountPoint + "/pressed.txt"))
        #expect(!FileManager.default.fileExists(atPath: image.mountPoint + "/earlier.txt"))
        try await image.detach()
    }
}
