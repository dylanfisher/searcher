import Base
import Foundation
import TestSupport
import Testing

@testable import Browser

/// A file with the hidden flag, as `chflags hidden` sets it.
private func flagged(_ name: String) -> DirectoryEntry {
    DirectoryEntry(
        name: name, type: .regular, size: 1, modified: testDate, isHidden: true,
        isDataless: false)
}

@MainActor
private func run(_ chord: KeyChord, on pane: Pane) throws {
    let registry = try AppCommands.registry()
    let command = try #require(registry.command(for: chord), "nothing is bound to \(chord)")
    let binding = try #require(AppCommands.bindings.first { $0.command == command })
    binding.run(CommandContext(pane: pane))
}

@MainActor
private func run(_ command: Command, on pane: Pane) throws {
    let binding = try #require(AppCommands.bindings.first { $0.command == command })
    binding.run(CommandContext(pane: pane))
}

private let toggleHidden = KeyChord(".", modifiers: [.command, .shift])

private func sortKey(_ digit: Character) -> KeyChord {
    KeyChord(.character(digit), modifiers: [.control, .option, .command])
}

/// A pane at `/view` over `entries`, loaded, with settings stored in `folder`.
@MainActor
private func viewPane(_ entries: [DirectoryEntry], in folder: TemporaryFolder) async
    -> PaneFixture
{
    let fixture = PaneFixture(
        at: "/view", folders: ["/view": entries], settings: storedSettings(in: folder))
    await settle { fixture.pane.state.isLoaded }
    return fixture
}

@MainActor
@Test(
    arguments: [
        // (key, column, first direction)
        ("1", SortColumn.name, true), ("2", .kind, true), ("5", .dateModified, false),
        ("6", .size, false),
    ] as [(Character, SortColumn, Bool)])
func aSortKeySortsByItsColumnAndTheSameKeyAgainReverses(
    digit: Character, column: SortColumn, firstAscending: Bool
) async throws {
    let temp = try TemporaryFolder("ViewCommandsTests")
    // Sorted by kind first, so every key, Name's included, changes the column.
    let fixture = PaneFixture(
        at: "/view", folders: ["/view": [file("a", size: 2), file("b.txt", size: 1)]],
        settings: storedSettings(in: temp), sortedBy: .kind, ascending: false)
    await settle { fixture.pane.state.isLoaded }
    let pane = fixture.pane

    try run(sortKey(digit), on: pane)
    #expect(pane.sortColumn == column)
    #expect(pane.sortAscending == firstAscending)
    await settle { pane.state.listing?.column == column }

    try run(sortKey(digit), on: pane)
    #expect(pane.sortColumn == column)
    #expect(pane.sortAscending == !firstAscending)
    await settle { pane.state.listing?.ascending == !firstAscending }
}

@MainActor @Test func commandShiftPeriodTogglesHiddenFilesInThePane() async throws {
    let temp = try TemporaryFolder("ViewCommandsTests")
    let fixture = await viewPane([file("a"), file(".dot"), flagged("flagged")], in: temp)
    let pane = fixture.pane
    #expect(pane.state.names == ["a"])

    try run(toggleHidden, on: pane)
    #expect(pane.settings.showHidden)
    await settle { pane.state.names.count == 3 }

    try run(toggleHidden, on: pane)
    #expect(!pane.settings.showHidden)
    await settle { pane.state.names == ["a"] }
}

@MainActor @Test func foldersFirstTogglesTheSettingAndPutsFoldersFirst() async throws {
    let temp = try TemporaryFolder("ViewCommandsTests")
    let fixture = await viewPane([file("a"), folder("b"), file("c"), folder("d")], in: temp)
    let pane = fixture.pane
    let binding = try #require(
        AppCommands.bindings.first { $0.command == ViewCommands.toggleFoldersFirst })
    let isChecked = try #require(binding.isChecked)
    #expect(!isChecked(pane.settings))

    try run(ViewCommands.toggleFoldersFirst, on: pane)

    #expect(pane.settings.foldersFirst)
    #expect(isChecked(pane.settings))
    await settle { pane.state.names == ["b", "d", "a", "c"] }
}

@MainActor @Test func aToggleKeepsTheSelectedEntryWhileItStaysVisible() async throws {
    let temp = try TemporaryFolder("ViewCommandsTests")
    let fixture = await viewPane([file("a"), flagged("b"), file("c"), folder("d")], in: temp)
    let pane = fixture.pane
    fixture.select("c")

    try run(toggleHidden, on: pane)
    await settle { pane.state.names == ["a", "b", "c", "d"] }
    try run(ViewCommands.toggleFoldersFirst, on: pane)
    await settle { pane.state.names == ["d", "a", "b", "c"] }

    #expect(pane.selection == Selection([ExactName("c")], cursor: ExactName("c")))
    let listing = try #require(pane.state.listing)
    #expect(pane.selection.rows(in: listing) == [3])
}

@MainActor @Test func hidingTheSelectedEntrySelectsTheNearestFollowingRow() async throws {
    let temp = try TemporaryFolder("ViewCommandsTests")
    let fixture = await viewPane([file("a"), flagged("b"), file("c"), flagged("d")], in: temp)
    let pane = fixture.pane
    try run(toggleHidden, on: pane)
    await settle { pane.state.names == ["a", "b", "c", "d"] }

    fixture.select("b")
    try run(toggleHidden, on: pane)
    await settle { pane.state.names == ["a", "c"] }
    #expect(pane.selection == Selection([ExactName("c")], cursor: ExactName("c")))
    #expect(pane.state.listing.map { pane.selection.rows(in: $0) } == [1])

    // With nothing after it, the last row is the nearest.
    try run(toggleHidden, on: pane)
    await settle { pane.state.names == ["a", "b", "c", "d"] }
    fixture.select("d")
    try run(toggleHidden, on: pane)
    await settle { pane.state.names == ["a", "c"] }
    #expect(pane.selection == Selection([ExactName("c")], cursor: ExactName("c")))
}

/// Holds `pane`'s sorts until the test resumes the returned queue.
@MainActor
private func holdSorts(of pane: Pane) -> DispatchQueue {
    let held = DispatchQueue(label: "held sorts")
    held.suspend()
    pane.sortQueue = held
    return held
}

@MainActor @Test func aToggleUndoneBeforeItsSortLandsShowsNoHiddenRows() async throws {
    let temp = try TemporaryFolder("ViewCommandsTests")
    let fixture = await viewPane([file("a"), file(".dot"), flagged("b")], in: temp)
    let pane = fixture.pane
    let held = holdSorts(of: pane)

    pane.settings.showHidden = true
    pane.settings.showHidden = false
    held.resume()
    await withCheckedContinuation { continuation in held.async { continuation.resume() } }
    await drainMainQueue()

    #expect(pane.state.names == ["a"])
}

/// ↓ moves onto "b" while the sort that hides it runs, so the pane shows that selection
/// provisionally and settles it after the sort lands.
@MainActor @Test func movingOntoAnEntryWhileItIsBeingHiddenSelectsTheNearestFollowingRow()
    async throws
{
    let temp = try TemporaryFolder("ViewCommandsTests")
    let fixture = await viewPane([file("a"), flagged("b"), file("c")], in: temp)
    let pane = fixture.pane
    try run(toggleHidden, on: pane)
    await settle { pane.state.names == ["a", "b", "c"] }
    fixture.select("a")
    let held = holdSorts(of: pane)

    try run(toggleHidden, on: pane)
    pane.moveSelection(by: 1)
    #expect(pane.selection == Selection([ExactName("b")], cursor: ExactName("b")))
    held.resume()

    await settle { pane.state.names == ["a", "c"] && pane.selection.isSettled }
    #expect(pane.selection == Selection([ExactName("c")], cursor: ExactName("c")))
}

/// The first batch is the first `ListingService.firstBatchCount` entries read, and with hidden
/// files off it shows fewer rows than that. Cmd-A there selects the rows it shows, and the full
/// listing keeps exactly those: no hidden entry and nothing read later.
@MainActor @Test func commandAOnAFirstBatchWithHiddenFilesSelectsTheRowsItShows() async throws {
    let temp = try TemporaryFolder("ViewCommandsTests")
    let entries = (0..<1_000).map { index in
        index.isMultiple(of: 50)
            ? file(String(format: ".w%04d", index)) : file(String(format: "w%04d", index))
    }
    let lister = GatedLister(["/wide": .batches([Array(entries[0..<300]), Array(entries[300...])])])
    lister.releaseAll()
    let pane = Pane(
        location: Location(path: "/wide"), service: ListingService(lister: lister),
        systemActions: StubSystemActions(), settings: storedSettings(in: temp))
    var firstBatchRows: Int?
    pane.onChange = {
        guard case .partial(let listing) = pane.state, firstBatchRows == nil else { return }
        firstBatchRows = listing.count
        pane.selectAll()
    }

    await settle { pane.state.isLoaded && pane.selection.isSettled }

    let shown = try #require(firstBatchRows)
    #expect(shown == ListingService.firstBatchCount - ListingService.firstBatchCount / 50)
    let listing = try #require(pane.state.listing)
    #expect(pane.selection.rows(in: listing).count == shown)
    #expect(pane.selection.rows(in: listing) == IndexSet(0..<shown))
}

#if DEBUG
    /// Every row selected in a 4,000-entry folder with a dot file in every tenth: the toggles
    /// re-filter, re-sort and resolve the selection off the main thread.
    @MainActor @Test func theTogglesDoNoPerEntryWorkOnTheMainThread() async throws {
        let temp = try TemporaryFolder("ViewCommandsTests")
        let entries = (0..<4_000).map { index in
            index.isMultiple(of: 10)
                ? file(String(format: ".w%04d", index)) : file(String(format: "w%04d", index))
        }
        let fixture = await viewPane(entries, in: temp)
        let pane = fixture.pane
        #expect(pane.state.listing?.count == 3_600)
        pane.selectAll()
        let work = pane.mainSelectionWork

        try run(toggleHidden, on: pane)
        await settle { pane.state.listing?.count == 4_000 }
        // The dot files Select All never saw aren't selected.
        await settle { pane.selection.isSettled }
        #expect(!pane.selection.contains(ExactName(".w0000")))
        #expect(pane.selection.contains(ExactName("w0001")))
        try run(ViewCommands.toggleFoldersFirst, on: pane)
        await settle { pane.state.listing?.foldersFirst == true }
        try run(toggleHidden, on: pane)
        await settle { pane.state.listing?.count == 3_600 }

        #expect(pane.mainSelectionWork - work < 100)
        let listing = try #require(pane.state.listing)
        #expect(pane.selection.rows(in: listing) == IndexSet(0..<3_600))
    }
#endif
