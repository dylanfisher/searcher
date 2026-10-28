import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing
import UniformTypeIdentifiers

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
private let getInfo = KeyChord("i", modifiers: [.command])

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

@MainActor @Test func getInfoAsksForTheInfoOfEachSelectedItemInDisplayOrder() async throws {
    let fixture = await systemPane()
    fixture.select("c", "a")

    try run(getInfo, on: fixture.pane)

    #expect(
        fixture.actions.shownInfo == [
            [
                URL(fileURLWithPath: "/sys/a", isDirectory: false),
                URL(fileURLWithPath: "/sys/c", isDirectory: false),
            ]
        ])
}

/// Finder's Get Info is never off in a folder: with nothing selected it shows the folder's Info
/// window.
@MainActor @Test func getInfoWithNothingSelectedAsksForTheFoldersInfo() async throws {
    let fixture = await systemPane()

    #expect(try isEnabled(getInfo, on: fixture.pane))
    try run(getInfo, on: fixture.pane)

    #expect(fixture.actions.shownInfo == [[URL(fileURLWithPath: "/sys", isDirectory: true)]])
}

@MainActor @Test func getInfoInAColumnAsksForTheColumnsSelection() async throws {
    let fixture = PaneFixture(
        at: "/sys",
        folders: ["/": [folder("sys")], "/sys": [folder("d"), file("a")], "/sys/d": [file("x")]])
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.setViewMode(.column)
    let trail = try #require(fixture.pane.columnTrail)
    await settle { trail.focused.pane.state.isLoaded }
    trail.focused.pane.select(Selection([ExactName("d")], cursor: ExactName("d")))
    await settle { trail.columns.count == 3 && trail.columns[2].pane.state.isLoaded }
    trail.moveRight()

    try run(getInfo, on: fixture.pane.commandPane)

    #expect(fixture.actions.shownInfo == [[URL(fileURLWithPath: "/sys/d/x", isDirectory: false)]])
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
    let held = heldQueue("held settles")
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

// MARK: At a server

@MainActor
private func isEnabled(_ chord: KeyChord, on pane: Pane) throws -> Bool {
    let registry = try AppCommands.registry()
    let command = try #require(registry.command(for: chord), "nothing is bound to \(chord)")
    let binding = try #require(AppCommands.bindings.first { $0.command == command })
    return binding.isEnabled?(CommandContext(pane: pane)) ?? true
}

/// A server has no folder, so with nothing selected there is nothing to act on, and no folder to
/// open a terminal in (0114-server-location.md).
@MainActor @Test func atAServerTheFolderCommandsAreOffAndDoNothing() async throws {
    let fixture = await PaneFixture.atServer()

    for chord in [copyPath, reveal, getInfo, openTerminal] {
        #expect(try !isEnabled(chord, on: fixture.pane), "\(chord)")
        try run(chord, on: fixture.pane)
    }

    #expect(fixture.actions.copiedTexts.isEmpty)
    #expect(fixture.actions.revealed.isEmpty)
    #expect(fixture.actions.shownInfo.isEmpty)
    #expect(fixture.actions.openedInApp.isEmpty)
}

/// A selected share is a folder in /Volumes, which Get Info and the others act on as on any
/// folder; Open Terminal Here, of the pane's folder, stays off.
@MainActor @Test func atAServerTheCommandsActOnTheSelectedShares() async throws {
    let fixture = await PaneFixture.atServer()
    fixture.select("music")
    let music = URL(fileURLWithPath: "/Volumes/music", isDirectory: true)

    for chord in [copyPath, reveal, getInfo] {
        #expect(try isEnabled(chord, on: fixture.pane), "\(chord)")
        try run(chord, on: fixture.pane)
    }

    #expect(fixture.actions.copiedTexts == ["/Volumes/music"])
    #expect(fixture.actions.revealed == [[music]])
    #expect(fixture.actions.shownInfo == [[music]])
    #expect(try !isEnabled(openTerminal, on: fixture.pane))
}

// MARK: Open Config File

private let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")

/// Settings whose config file is `file`, over a suite in the file's test folder.
@MainActor
private func configured(_ folder: TemporaryFolder, file: URL) -> Settings {
    Settings(
        defaults: temporarySuite(in: folder.url.path), configFile: file,
        log: unexpectedSettingsLog)
}

private func openConfigBinding() throws -> CommandBinding {
    try #require(AppCommands.bindings.first { $0.command == SystemCommands.openConfigFile })
}

/// With no file and no folder, the command makes both, the file from the template, and opens it
/// in the default app for plain text.
@MainActor @Test func openConfigFileWithNoFileCreatesItFromTheTemplate() async throws {
    let folder = try TemporaryFolder("SystemCommandsTests")
    let file = folder.url.appending(path: "searcher/config")
    let settings = configured(folder, file: file)
    let fixture = await systemPane(settings: settings)
    fixture.actions.setApplications([:], defaultApplications: [.plainText: textEdit])
    let binding = try openConfigBinding()
    #expect(binding.isEnabled?(CommandContext(pane: fixture.pane)) ?? true)

    binding.run(CommandContext(pane: fixture.pane))
    await settle { !fixture.actions.openedWithApp.isEmpty }

    #expect(try String(contentsOf: file, encoding: .utf8) == ConfigTemplate.text)
    #expect(fixture.actions.openedWithApp == [OpenedWithApp(urls: [file], application: textEdit)])
}

@MainActor @Test func openConfigFileWithAFileOpensItAndLeavesItsBytes() async throws {
    let folder = try TemporaryFolder("SystemCommandsTests")
    let file = folder.url.appending(path: "config")
    let bytes = Data("show-hidden = true\n".utf8)
    try bytes.write(to: file)
    let actions = StubSystemActions(defaultApplications: [.plainText: textEdit])

    await SystemCommands.openConfig(
        settings: configured(folder, file: file), systemActions: actions
    )
    .value

    #expect(try Data(contentsOf: file) == bytes)
    #expect(actions.openedWithApp == [OpenedWithApp(urls: [file], application: textEdit)])
}

/// A file that can't be made shows in the banner, and nothing opens.
@MainActor @Test func aConfigFileThatCantBeCreatedIsReported() async throws {
    let folder = try TemporaryFolder("SystemCommandsTests")
    // The file's folder is a file, so neither can be made.
    try Data().write(to: folder.url.appending(path: "searcher"))
    let file = folder.url.appending(path: "searcher/config")
    let settings = configured(folder, file: file)
    let actions = StubSystemActions(defaultApplications: [.plainText: textEdit])

    await SystemCommands.openConfig(settings: settings, systemActions: actions).value

    #expect(settings.configErrors.count == 1)
    #expect(settings.configErrors.first?.description.contains("couldn't be created") == true)
    #expect(actions.openedWithApp.isEmpty)
    #expect(actions.openedFiles.isEmpty)
}

/// A symbolic link at the config file's path to a file that isn't there is reported, not opened
/// or written through.
@MainActor @Test func aConfigFileLinkToNothingIsReported() async throws {
    let folder = try TemporaryFolder("SystemCommandsTests")
    let file = folder.url.appending(path: "config")
    let target = folder.url.appending(path: "dotfiles/config")
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    let settings = configured(folder, file: file)
    let actions = StubSystemActions(defaultApplications: [.plainText: textEdit])

    await SystemCommands.openConfig(settings: settings, systemActions: actions).value

    #expect(
        settings.configErrors.map(\.description) == [
            "couldn't be created: it is a symbolic link to \(target.path), which doesn't exist"
        ])
    #expect(actions.openedWithApp.isEmpty)
    #expect(actions.openedFiles.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: target.path))
}

/// Settings with no config file, as the tests' and the bench's, leave the command off.
@MainActor @Test func openConfigFileIsOffWithoutAConfigFile() async throws {
    let fixture = await systemPane()

    #expect(try openConfigBinding().isEnabled?(CommandContext(pane: fixture.pane)) == false)
}
