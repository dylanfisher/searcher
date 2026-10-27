import Base
import Browser
import Foundation

extension BenchCase {
    /// Reading a folder's cut names after Select All and Cut on W2, as a list does each time its
    /// pane changes: every patch, sort, load update and size batch, in every list and column
    /// showing the folder, on the main thread, so a slow read adds to a B6 frame. The first case
    /// times a read after the folder's names have been read once for this cut, as every read but
    /// the cut's first is; the second times that first read, which `CutState` keeps for the
    /// rest of the cut. The paths come from W2's entry list, not the disk, and the cut is made
    /// untimed on a clipboard in memory. A `--path` folder doesn't apply.
    static let cutNames: [BenchCase] = [
        BenchCase(
            name: "W2 cut: cut names read on a pane change", budget: budget("B6"),
            unit: .milliseconds
        ) { _ in await timeCutNames(afterFirstRead: true) },
        BenchCase(name: "W2 cut: first cut names read", budget: nil, unit: .milliseconds) { _ in
            await timeCutNames(afterFirstRead: false)
        },
    ]

    /// Every W2 entry's file URL.
    private static let cutNamesURLs: [URL] = {
        let folder = Fixture(.w2).path
        return Fixture(.w2).entries.map { folder.appending(path: $0.path) }
    }()

    @MainActor
    private static func timeCutNames(afterFirstRead: Bool) -> Double {
        let urls = cutNamesURLs
        let folder = Location(path: Fixture(.w2).path.path)
        let state = CutState(clipboard: BenchClipboard())
        state.cut(urls)
        if afterFirstRead {
            _ = state.cutNames(in: folder)
        }
        let start = ContinuousClock.now
        let names = state.cutNames(in: folder)
        let elapsed = milliseconds(.now - start)
        guard names.count == urls.count else {
            preconditionFailure("read \(names.count) of \(urls.count) cut names")
        }
        return elapsed
    }
}

/// A clipboard in memory, so the bench writes no pasteboard.
@MainActor
private final class BenchClipboard: FileClipboard {
    private(set) var changeCount = 0
    private var urls: [URL] = []

    func write(_ urls: [URL]) {
        self.urls = urls
        changeCount += 1
    }

    func fileURLs() -> [URL] { urls }
}
