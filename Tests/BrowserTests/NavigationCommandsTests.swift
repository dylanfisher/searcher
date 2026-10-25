import Base
import BrowserTestSupport
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Browser

@MainActor
private func binding(for chord: KeyChord) throws -> CommandBinding {
    let registry = try AppCommands.registry()
    let command = try #require(registry.command(for: chord))
    return try #require(AppCommands.bindings.first { $0.command == command })
}

@MainActor
private func run(
    _ chord: KeyChord, on pane: Pane,
    askForFolder: @escaping @MainActor () -> Void = { Issue.record("asked for a folder") }
) throws {
    try binding(for: chord).run(CommandContext(pane: pane, askForFolder: askForFolder))
}

@MainActor
private func run(_ chord: KeyChord, in fixture: PaneFixture) throws {
    try run(chord, on: fixture.pane)
}

/// Whether the command on `chord` can run on `fixture`'s pane, as its menu item shows it.
@MainActor
private func isEnabled(_ chord: KeyChord, in fixture: PaneFixture) throws -> Bool {
    let binding = try binding(for: chord)
    let context = CommandContext(
        pane: fixture.pane, askForFolder: { Issue.record("asked for a folder") })
    return binding.isEnabled?(context) ?? true
}

private let back = KeyChord("[", modifiers: .command)
private let forward = KeyChord("]", modifiers: .command)
private let goToFolder = KeyChord("g", modifiers: [.command, .shift])

/// A pane at `/a` over folders `/a`, `/b` and `/c`, already loaded.
@MainActor
private func threeFolders() async -> PaneFixture {
    let fixture = PaneFixture(
        at: "/a",
        folders: [
            "/a": [file("a1"), file("a2"), file("a3")], "/b": [file("b1"), file("b2")],
            "/c": [file("c1")],
        ])
    await settle { fixture.pane.state.isLoaded }
    return fixture
}

// MARK: Packages

/// A pane at `/root` holding a package `App.app`, a folder `docs` and a file `a.txt`, loaded.
@MainActor
private func packagePane() async -> PaneFixture {
    let fixture = PaneFixture(
        at: "/root",
        folders: [
            "/root": [package("App.app"), folder("docs"), file("a.txt")],
            "/root/App.app": [folder("Contents")], "/root/docs": [file("x")],
        ])
    await settle { fixture.pane.state.isLoaded }
    return fixture
}

@MainActor
private func showPackageContents() throws -> CommandBinding {
    try #require(
        AppCommands.bindings.first { $0.command == NavigationCommands.showPackageContents })
}

@MainActor @Test func showPackageContentsBrowsesIntoTheSelectedPackageAsAFolder() async throws {
    let fixture = await packagePane()
    fixture.select("App.app")
    let binding = try showPackageContents()
    #expect(binding.isEnabled?(CommandContext(pane: fixture.pane)) == true)

    binding.run(CommandContext(pane: fixture.pane))

    #expect(fixture.pane.location.path == "/root/App.app")
    await settle { fixture.pane.state.isLoaded }
    #expect(fixture.pane.state.names == ["Contents"])
    #expect(fixture.pane.canGoBack)
    #expect(fixture.actions.openedFiles.isEmpty)
}

@MainActor @Test func showPackageContentsIsOffAndDoesNothingWithoutOneSelectedPackage()
    async throws
{
    let fixture = await packagePane()
    let binding = try showPackageContents()

    for names in [["a.txt"], ["docs"], ["App.app", "a.txt"], []] {
        fixture.pane.select(
            Selection(Set(names.map(ExactName.init)), cursor: names.last.map(ExactName.init)))
        #expect(binding.isEnabled?(CommandContext(pane: fixture.pane)) == false, "\(names)")

        binding.run(CommandContext(pane: fixture.pane))

        #expect(fixture.pane.location.path == "/root", "\(names)")
    }
    #expect(fixture.actions.openedFiles.isEmpty)
}

/// Cmd-↓ is Open in Finder, so on a package it opens the package as a file.
@MainActor @Test func cmdDownOnAPackageOpensItAsAFile() async throws {
    let fixture = await packagePane()
    fixture.select("App.app")

    try run(KeyChord(.down, modifiers: .command), in: fixture)

    #expect(fixture.actions.openedFiles == [URL(fileURLWithPath: "/root/App.app")])
    #expect(fixture.pane.location.path == "/root")
}

@MainActor
private func navigate(_ fixture: PaneFixture, to path: String) async {
    fixture.pane.navigate(to: Location(path: path))
    await settle { fixture.pane.state.isLoaded }
}

@MainActor @Test func commandDownOpensTheSelectedFolder() async throws {
    let fixture = await PaneFixture.loaded()
    fixture.select("docs")

    try run(KeyChord(.down, modifiers: .command), in: fixture)

    #expect(fixture.pane.location == Location(path: "/root/docs"))
}

@MainActor @Test func commandOOpensTheSelectedFile() async throws {
    let fixture = await PaneFixture.loaded()
    fixture.select("b.txt")

    try run(KeyChord("o", modifiers: .command), in: fixture)

    #expect(fixture.actions.openedFiles.map(\.path) == ["/root/b.txt"])
}

@MainActor @Test func commandUpGoesToTheParent() async throws {
    let fixture = await PaneFixture.loaded()

    try run(KeyChord(.up, modifiers: .command), in: fixture)

    #expect(fixture.pane.location == Location(path: "/"))
}

@MainActor @Test func plainArrowsMoveTheSelection() async throws {
    let fixture = await PaneFixture.loaded()
    fixture.select("a.txt")

    try run(KeyChord(.down), in: fixture)
    #expect(fixture.selectedNames == ["b.txt"])
    try run(KeyChord(.up), in: fixture)
    try run(KeyChord(.up), in: fixture)
    #expect(fixture.selectedNames == ["a.txt"])
}

// MARK: - Back and forward

@MainActor @Test func backTwiceReturnsToTheFirstFolderWithTheEntrySelectedThere() async throws {
    let fixture = await threeFolders()
    fixture.select("a2")
    await navigate(fixture, to: "/b")
    fixture.select("b2")
    await navigate(fixture, to: "/c")

    try run(back, in: fixture)
    await settle { fixture.pane.state.isLoaded }
    #expect(fixture.pane.location == Location(path: "/b"))
    #expect(fixture.selectedNames == ["b2"])

    try run(back, in: fixture)
    await settle { fixture.pane.state.isLoaded && fixture.pane.selection.isSettled }
    #expect(fixture.pane.location == Location(path: "/a"))
    #expect(fixture.selectedNames == ["a2"])
    #expect(fixture.pane.selection.cursor == ExactName("a2"))
}

@MainActor @Test func forwardReturnsWithTheEntrySelectedWhenBackLeft() async throws {
    let fixture = await threeFolders()
    await navigate(fixture, to: "/b")
    fixture.select("b1")
    try run(back, in: fixture)
    await settle { fixture.pane.state.isLoaded }

    try run(forward, in: fixture)
    await settle { fixture.pane.state.isLoaded }

    #expect(fixture.pane.location == Location(path: "/b"))
    #expect(fixture.selectedNames == ["b1"])
}

@MainActor @Test func aNewNavigationAfterBackClearsForward() async throws {
    let fixture = await threeFolders()
    await navigate(fixture, to: "/b")
    try run(back, in: fixture)
    await settle { fixture.pane.state.isLoaded }
    #expect(try isEnabled(forward, in: fixture))

    await navigate(fixture, to: "/c")

    #expect(try !isEnabled(forward, in: fixture))
    try run(forward, in: fixture)
    #expect(fixture.pane.location == Location(path: "/c"))
    #expect(fixture.pane.state.isLoaded)
}

@MainActor @Test func backAtTheStartAndForwardAtTheEndDoNothingAndAreDisabled() async throws {
    let fixture = await threeFolders()
    #expect(try !isEnabled(back, in: fixture))
    #expect(try !isEnabled(forward, in: fixture))

    try run(back, in: fixture)
    try run(forward, in: fixture)
    #expect(fixture.pane.location == Location(path: "/a"))
    #expect(fixture.pane.state.isLoaded)

    await navigate(fixture, to: "/b")
    #expect(try isEnabled(back, in: fixture))
    #expect(try !isEnabled(forward, in: fixture))
    try run(forward, in: fixture)
    #expect(fixture.pane.location == Location(path: "/b"))
    #expect(fixture.pane.state.isLoaded)
}

@MainActor @Test func goToParentAndOpenAreStepsInHistory() async throws {
    let fixture = await PaneFixture.loaded()
    fixture.select("docs")
    try run(KeyChord(.down, modifiers: .command), in: fixture)
    await settle { fixture.pane.state.isLoaded }
    try run(KeyChord(.up, modifiers: .command), in: fixture)
    await settle { fixture.pane.state.isLoaded }
    #expect(fixture.pane.location == Location(path: "/root"))

    try run(back, in: fixture)
    await settle { fixture.pane.state.isLoaded }
    #expect(fixture.pane.location == Location(path: "/root/docs"))
    try run(back, in: fixture)
    await settle { fixture.pane.state.isLoaded }
    #expect(fixture.pane.location == Location(path: "/root"))
    #expect(fixture.selectedNames == ["docs"])
}

@MainActor @Test func aFolderDeletedWhileInHistoryFailsWhenSteppedTo() async throws {
    let root = try TemporaryFolder("NavigationCommandsTests")
    let a = root.url.appending(path: "a").path
    let b = root.url.appending(path: "b").path
    for path in [a, b] {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    }
    let pane = Pane(
        location: Location(path: a), service: ListingService(),
        systemActions: StubSystemActions(), settings: untouchedSettings())
    await settle { pane.state.isLoaded }
    pane.navigate(to: Location(path: b))
    await settle { pane.state.isLoaded }
    try FileManager.default.removeItem(atPath: a)

    try run(back, on: pane)
    await settle { pane.state.isFailed }

    #expect(pane.location == Location(path: a))
    guard case .failed(let error) = pane.state else { return }
    #expect(error.reason == .notFound)
    #expect(pane.canGoForward)
}

// MARK: - Go to folder

@MainActor @Test func goToFolderAsksForAFolder() async throws {
    let fixture = await PaneFixture.loaded()
    var asked = 0

    try run(goToFolder, on: fixture.pane) { asked += 1 }

    #expect(asked == 1)
}

/// A pane at `/root`, loaded, with `/root/docs` held until the test releases it, `/gone`
/// missing, `/file` a file, `/secret` behind privacy protection and `/other` a folder.
@MainActor
private func goToFixture() async -> (Pane, GatedLister) {
    let lister = GatedLister([
        "/root": .batches([[folder("docs"), file("a.txt")]]),
        "/root/docs": .batches([[file("inside.txt")]]),
        "/gone": .failure(ListingError(path: "/gone", code: ENOENT)),
        "/file": .failure(ListingError(path: "/file", code: ENOTDIR)),
        "/secret": .failure(ListingError(path: "/secret", code: EPERM)),
        "/other": .batches([[file("o.txt")]]),
    ])
    for path in ["/root", "/gone", "/file", "/secret", "/other"] { lister.release(path) }
    let pane = Pane(
        location: Location(path: "/root"), service: ListingService(lister: lister),
        systemActions: StubSystemActions(), settings: untouchedSettings())
    await settle { pane.state.isLoaded }
    return (pane, lister)
}

/// What `goToFolder` reported: nil until it finished, then the error it stayed for, if any.
@MainActor
private final class GoResult {
    var finished = false
    var error: ListingError?

    func record(_ error: ListingError?) {
        #expect(!finished, "goToFolder finished twice")
        finished = true
        self.error = error
    }
}

@MainActor @Test(arguments: [("/gone", ENOENT), ("/file", ENOTDIR)])
func goToAMissingFolderReportsItAndLeavesThePaneWhereItWas(path: String, code: Int32) async {
    let (pane, _) = await goToFixture()
    pane.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))
    let result = GoResult()
    var changes = 0
    pane.onChange = { changes += 1 }

    pane.goToFolder(Location(path: path), then: result.record)
    await settle { result.finished }

    #expect(result.error == ListingError(path: path, code: code))
    #expect(pane.location == Location(path: "/root"))
    #expect(pane.state.names == ["a.txt", "docs"])
    #expect(pane.selection.cursor == ExactName("a.txt"))
    #expect(!pane.canGoBack)
    #expect(changes == 0)
}

@MainActor @Test func goToFolderSwitchesOnlyOnceTheFolderLists() async {
    let (pane, lister) = await goToFixture()
    let result = GoResult()

    pane.goToFolder(Location(path: "/root/docs"), then: result.record)
    #expect(await lister.waitForCall("/root/docs"))
    await drainMainQueue()
    #expect(pane.location == Location(path: "/root"))
    #expect(pane.state.isLoaded)
    #expect(!result.finished)

    lister.release("/root/docs")
    await settle { result.finished }

    #expect(result.error == nil)
    #expect(pane.location == Location(path: "/root/docs"))
    #expect(pane.state.names == ["inside.txt"])
    #expect(pane.canGoBack)
    pane.goBack()
    await settle { pane.state.isLoaded && pane.location == Location(path: "/root") }
}

@MainActor @Test func goToAFolderTheAppCantReadShowsWhy() async {
    let (pane, _) = await goToFixture()
    let result = GoResult()

    pane.goToFolder(Location(path: "/secret"), then: result.record)
    await settle { result.finished }

    #expect(result.error == nil)
    #expect(pane.location == Location(path: "/secret"))
    #expect(pane.state.isDenied)
}

@MainActor @Test func aCancelledGoToFolderNeverMovesThePane() async {
    let (pane, lister) = await goToFixture()
    let result = GoResult()

    pane.goToFolder(Location(path: "/root/docs"), then: result.record)
    #expect(await lister.waitForCall("/root/docs"))
    pane.cancelGoToFolder()
    lister.release("/root/docs")
    #expect(await lister.waitForFinished(2))
    await drainMainQueue()

    #expect(!result.finished)
    #expect(pane.location == Location(path: "/root"))
    #expect(pane.state.names == ["a.txt", "docs"])
}

@MainActor @Test func aNavigationDuringAPendingGoToFolderWins() async {
    let (pane, lister) = await goToFixture()
    let result = GoResult()
    pane.goToFolder(Location(path: "/root/docs"), then: result.record)
    #expect(await lister.waitForCall("/root/docs"))

    pane.navigate(to: Location(path: "/other"))
    await settle { pane.state.isLoaded }
    lister.release("/root/docs")
    #expect(await lister.waitForFinished(3))
    await drainMainQueue()

    #expect(!result.finished)
    #expect(pane.location == Location(path: "/other"))
    #expect(pane.state.names == ["o.txt"])
}

@MainActor @Test func backDuringAPendingGoToFolderWins() async {
    let (pane, lister) = await goToFixture()
    pane.navigate(to: Location(path: "/other"))
    await settle { pane.state.isLoaded }
    let result = GoResult()
    pane.goToFolder(Location(path: "/root/docs"), then: result.record)
    #expect(await lister.waitForCall("/root/docs"))

    pane.goBack()
    await settle { pane.state.isLoaded }
    lister.release("/root/docs")
    #expect(await lister.waitForFinished(4))
    await drainMainQueue()

    #expect(!result.finished)
    #expect(pane.location == Location(path: "/root"))
    #expect(pane.state.names == ["a.txt", "docs"])
}

@MainActor @Test func goingToThePanesOwnFolderReloadsItAndKeepsItsMonitor() async {
    let (pane, lister) = await goToFixture()
    let monitor = StubMonitor()
    pane.monitor = monitor
    let result = GoResult()

    pane.goToFolder(Location(path: "/root"), then: result.record)
    await settle { result.finished }
    #expect(await lister.waitForFinished(2))
    await settle { pane.state.isLoaded }

    #expect(result.error == nil)
    #expect(pane.location == Location(path: "/root"))
    #expect(monitor.stopCount == 0)
    #expect(pane.monitor as? StubMonitor === monitor)
    #expect(!pane.canGoBack)
}

@MainActor @Test func goToAFolderThatGoesSlowLeavesThePaneWhereItWas() async {
    let lister = GatedLister([
        "/root": .batches([[folder("docs"), file("a.txt")]]), "/root/slow": .blockForever,
    ])
    lister.releaseAll()
    let clock = ManualClock()
    let pane = Pane(
        location: Location(path: "/root"), service: ListingService(lister: lister, clock: clock),
        systemActions: StubSystemActions(), settings: untouchedSettings())
    await settle { pane.state.isLoaded }
    let result = GoResult()

    pane.goToFolder(Location(path: "/root/slow"), then: result.record)
    #expect(await lister.waitForCall("/root/slow"))
    clock.advance(by: LoadTimeouts.slow)
    // The slow update reaches the main queue from the load's timer task, with nothing to wait on.
    try? await Task.sleep(for: .milliseconds(200))
    await drainMainQueue()

    #expect(!result.finished)
    #expect(pane.location == Location(path: "/root"))
    #expect(pane.state.names == ["a.txt", "docs"])
    #expect(!pane.canGoBack)
}

@MainActor @Test func navigatingToThePanesOwnFolderKeepsItsMonitorAndIsNoStep() async {
    let (pane, _) = await goToFixture()
    let monitor = StubMonitor()
    pane.monitor = monitor

    pane.navigate(to: Location(path: "/root"), selecting: "docs")
    await settle { pane.state.isLoaded && pane.selection.isSettled }

    #expect(monitor.stopCount == 0)
    #expect(pane.monitor as? StubMonitor === monitor)
    #expect(!pane.canGoBack)
    #expect(pane.selection.cursor == ExactName("docs"))
}
