import Base
import Foundation
import TestSupport
import Testing

@testable import Browser

@MainActor
private func run(_ chord: KeyChord, on pane: Pane) throws {
    let registry = try AppCommands.registry()
    let command = try #require(registry.command(for: chord), "nothing is bound to \(chord)")
    let binding = try #require(AppCommands.bindings.first { $0.command == command })
    binding.run(CommandContext(pane: pane))
}

private let copyPath = KeyChord("c", modifiers: [.option, .command])
private let reveal = KeyChord("r", modifiers: [.option, .command])
private let openTerminal = KeyChord("t", modifiers: [.option, .command])

/// A pane at `/sys` with files "b", "a" and "c", sorted by name, loaded.
@MainActor
private func systemPane(settings: Settings = untouchedSettings()) async -> PaneFixture {
    let fixture = PaneFixture(
        at: "/sys", folders: ["/sys": [file("b"), file("a"), file("c")]], settings: settings)
    await settle { fixture.pane.state.isLoaded }
    return fixture
}

@MainActor @Test func copyPathWritesTheSelectedPathsOnePerLineInDisplayOrder() async throws {
    let fixture = await systemPane()
    fixture.select("c", "a")

    try run(copyPath, on: fixture.pane)

    #expect(fixture.actions.copiedTexts == ["/sys/a\n/sys/c"])
}

@MainActor @Test func copyPathFollowsTheSortShown() async throws {
    let fixture = await systemPane()
    fixture.pane.setSort(.name, ascending: false)
    await settle { fixture.pane.state.listing?.ascending == false }
    fixture.select("a", "c")

    try run(copyPath, on: fixture.pane)

    #expect(fixture.actions.copiedTexts == ["/sys/c\n/sys/a"])
}

@MainActor @Test func copyPathWithNothingSelectedWritesTheFoldersPath() async throws {
    let fixture = await systemPane()

    try run(copyPath, on: fixture.pane)

    #expect(fixture.actions.copiedTexts == ["/sys"])
}

@MainActor @Test func revealPassesTheSelectedURLs() async throws {
    let fixture = await systemPane()
    fixture.select("b", "a")

    try run(reveal, on: fixture.pane)

    #expect(
        fixture.actions.revealed == [
            [
                URL(fileURLWithPath: "/sys/a", isDirectory: false),
                URL(fileURLWithPath: "/sys/b", isDirectory: false),
            ]
        ])
}

@MainActor @Test func revealWithNothingSelectedRevealsTheFolder() async throws {
    let fixture = await systemPane()

    try run(reveal, on: fixture.pane)

    #expect(fixture.actions.revealed == [[URL(fileURLWithPath: "/sys", isDirectory: true)]])
}

@MainActor @Test func openTerminalPassesTheFolderAndTheConfiguredBundleID() async throws {
    let folder = try TemporaryFolder("SystemCommandsTests")
    let settings = storedSettings(in: folder)
    let fixture = await systemPane(settings: settings)
    fixture.select("a")

    try run(openTerminal, on: fixture.pane)
    settings.terminalBundleID = "com.googlecode.iterm2"
    try run(openTerminal, on: fixture.pane)

    let sys = URL(fileURLWithPath: "/sys", isDirectory: true)
    #expect(
        fixture.actions.openedInApp == [
            OpenedInApp(folder: sys, bundleID: "com.apple.Terminal"),
            OpenedInApp(folder: sys, bundleID: "com.googlecode.iterm2"),
        ])
}

/// Cmd-A while a patch runs leaves a provisional selection that knows only the rows near the
/// cursor; Copy Path still writes every selected path.
@MainActor @Test func copyPathOnAProvisionalSelectionWritesEverySelectedPath() async throws {
    let pane = Pane(
        location: Location(path: "/n"),
        service: ListingService(
            lister: StubLister(["/n": (0..<100).map { file(String(format: "n%03d", $0)) }])),
        systemActions: StubSystemActions(), settings: untouchedSettings())
    await settle { pane.state.isLoaded }
    let held = DispatchQueue(label: "held settles")
    held.suspend()
    pane.settleQueue = held
    let version = pane.stateVersion

    pane.apply(.patches([.update(file("a-new"))]), at: pane.location)
    pane.selectAll()
    await settle { pane.stateVersion != version }
    #expect(pane.selection.isProvisional)
    try run(copyPath, on: pane)
    held.resume()

    let actions = try #require(pane.systemActions as? StubSystemActions)
    let expected = (0..<100).map { String(format: "/n/n%03d", $0) }.joined(separator: "\n")
    #expect(actions.copiedTexts == [expected])
}

/// With hidden files hidden, ".dot" has no row, so Select All doesn't take it in.
@MainActor @Test func selectAllCopiesAndRevealsNoHiddenEntry() async throws {
    let fixture = PaneFixture(at: "/sys", folders: ["/sys": [file("a"), file(".dot"), file("b")]])
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.selectAll()

    try run(copyPath, on: fixture.pane)
    try run(reveal, on: fixture.pane)

    #expect(fixture.actions.copiedTexts == ["/sys/a\n/sys/b"])
    #expect(
        fixture.actions.revealed == [
            [
                URL(fileURLWithPath: "/sys/a", isDirectory: false),
                URL(fileURLWithPath: "/sys/b", isDirectory: false),
            ]
        ])
}

/// A folder `StubSystemActions` was asked to open in an app.
struct OpenedInApp: Equatable {
    let folder: URL
    let bundleID: String
}
