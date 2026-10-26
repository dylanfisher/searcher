import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser

/// `/r` holds folders `docs` and `other` and a file `a.txt`; `/r/docs` holds a folder `sub` and
/// a file `x.txt`.
private let tree: [String: [DirectoryEntry]] = [
    "/": [folder("r")],
    "/r": [folder("docs"), folder("other"), file("a.txt")],
    "/r/docs": [folder("sub"), file("x.txt"), file(".hidden")],
    "/r/docs/sub": [file("deep.txt")],
    "/r/other": [file("o.txt")],
]

/// A focused pane at `path` over `tree`, loaded, switched to column mode, with every column
/// loaded.
@MainActor
private func columnPane(at path: String = "/r", selecting name: String? = nil) async
    -> PaneFixture
{
    let fixture = PaneFixture(at: path, folders: tree)
    await settle { fixture.pane.state.isLoaded }
    if let name { fixture.select(name) }
    fixture.pane.setViewMode(.column)
    await settle { trail(fixture.pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    return fixture
}

@MainActor
private func trail(_ pane: Pane) -> ColumnTrail {
    guard let trail = pane.columnTrail else {
        preconditionFailure("the pane isn't in column mode")
    }
    return trail
}

@MainActor
private func paths(_ pane: Pane) -> [String] {
    trail(pane).columns.map(\.pane.location.path)
}

/// Selects `name` alone in `column`, as a click or a key does.
@MainActor
private func select(_ name: String, in column: Column) {
    column.pane.select(Selection([ExactName(name)], cursor: ExactName(name)))
}

/// Runs the command bound to `chord` on the pane keys act on, as the view does.
@MainActor
private func press(_ chord: KeyChord, on pane: Pane) throws {
    let registry = try AppCommands.registry()
    let command = try #require(registry.command(for: chord), "nothing is bound to \(chord)")
    let binding = try #require(AppCommands.bindings.first { $0.command == command })
    binding.run(CommandContext(pane: pane.commandPane))
}

@MainActor @Test func switchingToColumnModeStartsTheTrailAtThePanesLocation() async {
    let fixture = await columnPane(selecting: "a.txt")
    let pane = fixture.pane

    #expect(pane.viewMode == .column)
    #expect(paths(pane) == ["/", "/r"])
    #expect(trail(pane).focusedIndex == 1)
    #expect(trail(pane).focused.pane.selection.cursor == ExactName("a.txt"))
    #expect(pane.commandPane === trail(pane).focused.pane)
}

/// Every folder from the volume's root down to the pane's has a column, each with the next one
/// selected, as Finder's column view has; the pane's own folder's column takes the keys.
@MainActor @Test func switchingToColumnModeShowsAColumnForEveryFolderFromTheRoot() async {
    let fixture = await columnPane(at: "/r/docs", selecting: "x.txt")
    let pane = fixture.pane
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }

    #expect(paths(pane) == ["/", "/r", "/r/docs"])
    #expect(trail(pane).focusedIndex == 2)
    #expect(pane.location == Location(path: "/r/docs"))
    #expect(trail(pane).columns.map { $0.pane.selection.cursor?.name } == ["r", "docs", "x.txt"])
    #expect(trail(pane).preview?.location == Location(path: "/r/docs/x.txt"))
}

/// The pane's folder's load is the first one asked; the columns left of it list once the root
/// check answers, without waiting for that folder's first rows (0103-column-trail-from-the-root.md).
@MainActor @Test func theFoldersAboveListOnceTheRootIsCheckedBeforeTheFocusedFoldersRows() async {
    let lister = GatedLister(tree.mapValues { .batches([$0]) })
    lister.release("/")
    lister.release("/r")
    // Still, so the held load never goes slow, which would be its first update.
    let clock = ManualClock()

    let pane = Pane(
        location: Location(path: "/r/docs"), service: ListingService(lister: lister, clock: clock),
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true,
        viewMode: .column)

    #expect(paths(pane) == ["/", "/r", "/r/docs"])
    #expect(trail(pane).columns[2].pane.load != nil)
    #expect(trail(pane).columns[0].pane.load == nil)
    #expect(trail(pane).columns[1].pane.load == nil)
    await trail(pane).rootChecked()
    await settle { trail(pane).columns.prefix(2).allSatisfy { $0.pane.state.isLoaded } }
    #expect(trail(pane).focused.pane.state.isLoading)
    #expect(lister.calls.first?.path == "/r/docs")
    lister.releaseAll()
    await settle { trail(pane).focused.pane.state.isLoaded }
}

/// ← to a column whose load waits for the focused one's rows lists it at once.
@MainActor @Test func movingToAColumnWhoseLoadWaitsStartsIt() async throws {
    let fixture = PaneFixture(at: "/r/docs", folders: tree, held: true)
    fixture.lister.release("/r/docs")
    let pane = fixture.pane
    await settle { pane.state.isLoaded }
    fixture.lister.release("/r")
    fixture.lister.release("/")
    pane.setViewMode(.column)

    try press(KeyChord(.left), on: pane)

    #expect(trail(pane).focusedIndex == 1)
    #expect(trail(pane).columns[1].pane.load?.priority == .visible)
    #expect(trail(pane).columns[0].pane.load != nil)
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }
}

/// A folder above the pane's that its parent's rows don't show, hidden or behind a link, keeps
/// its column, and so does one whose parent can't be listed; another selection there drops it.
@MainActor @Test func aFolderItsParentDoesntShowOrCantListKeepsItsColumn() async throws {
    var outcomes = tree.mapValues { GatedLister.Outcome.batches([$0]) }
    // `/r` lists no `secret`, as it leaves out a hidden folder, and `/` can't be read.
    outcomes["/r/secret"] = .batches([[file("s.txt")]])
    outcomes["/"] = .failure(ListingError(path: "/", code: EACCES))
    let lister = GatedLister(outcomes)
    lister.releaseAll()
    let pane = Pane(
        location: Location(path: "/r/secret"), service: ListingService(lister: lister),
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true,
        viewMode: .column)

    await settle {
        trail(pane).columns.count == 3 && trail(pane).columns[0].pane.state.error != nil
            && trail(pane).columns[1].pane.state.isLoaded
            && trail(pane).columns[2].pane.state.isLoaded
    }
    await drainMainQueue()

    #expect(paths(pane) == ["/", "/r", "/r/secret"])
    #expect(trail(pane).focusedIndex == 2)
    let parent = trail(pane).columns[1].pane
    #expect(parent.selection.rows(in: try #require(parent.state.listing)).isEmpty)

    select("docs", in: trail(pane).columns[1])

    #expect(paths(pane) == ["/", "/r", "/r/docs"])
}

/// A path bar click on a folder whose column the trail shows moves the keys there and closes the
/// columns right of it, leaving the folder it came from as the cursor, unselected. Nothing lists
/// again, and it is a step in the history: Back starts the trail again at the folder left, since
/// its column has closed.
@MainActor @Test func aPathBarClickOnAShownFolderClosesTheColumnsRightOfIt() async throws {
    let fixture = await columnPane(at: "/r/docs", selecting: "sub")
    let pane = fixture.pane
    await settle { paths(pane) == ["/", "/r", "/r/docs", "/r/docs/sub"] }
    try press(KeyChord(.right), on: pane)
    await settle { trail(pane).focused.pane.selection.cursor == ExactName("deep.txt") }
    let back = pane.history.backEntries.count
    #expect(trail(pane).focusedIndex == 3)
    let columns = trail(pane).columns.prefix(2).map(\.pane)
    let listings = fixture.lister.calls.count

    pane.showFolderAbove(Location(path: "/r"), comingFrom: "docs")

    #expect(paths(pane) == ["/", "/r"])
    #expect(trail(pane).focusedIndex == 1)
    #expect(pane.location == Location(path: "/r"))
    #expect(trail(pane).columns.map(\.pane).elementsEqual(columns, by: ===))
    let shown = trail(pane).columns[1].pane.selection
    #expect(shown.isEmpty)
    #expect(shown.cursor == ExactName("docs"))
    #expect(
        pane.history.backEntries.last
            == History.Entry(
                location: Location(path: "/r/docs/sub"), selected: ExactName("deep.txt")))
    #expect(pane.history.backEntries.count == back + 1)
    await drainMainQueue()
    #expect(fixture.lister.calls.count == listings)

    try press(KeyChord("[", modifiers: .command), on: pane)

    #expect(paths(pane) == ["/", "/r", "/r/docs", "/r/docs/sub"])
    #expect(trail(pane).focusedIndex == 3)
    #expect(trail(pane).focused.pane.selection.cursor == ExactName("deep.txt"))
}

@MainActor @Test func aPathBarClickInTheListNavigatesSelectingTheFolderLeft() async throws {
    let fixture = PaneFixture(at: "/r/docs", folders: tree)
    let pane = fixture.pane
    await settle { pane.state.isLoaded }

    pane.showFolderAbove(Location(path: "/r"), comingFrom: "docs")

    #expect(pane.location == Location(path: "/r"))
    #expect(pane.selection.cursor == ExactName("docs"))
    #expect(pane.canGoBack)
}

@MainActor @Test func theTrailStartsAtTheRootOfTheFoldersVolume() {
    func root(_ path: String, _ volumes: [VolumeIdentity] = []) -> String {
        ColumnTrail.root(of: Location(path: path), mountedVolumes: volumes, home: nil).path
    }
    let startup = VolumeIdentity(device: "/dev/disk3s1", mountPoint: "/", kind: .local)
    let data = VolumeIdentity(
        device: "/dev/disk3s5", mountPoint: "/System/Volumes/Data", kind: .local,
        isBrowsable: false)
    let backup = VolumeIdentity(device: "/dev/disk5s1", mountPoint: "/Volumes/Backup", kind: .local)
    let share = VolumeIdentity(
        device: "//me@nas.invalid/s", mountPoint: "/Users/me/mnt/s", kind: .network)
    let mounted = [startup, data, backup, share]

    // Firmlinked folders, on the Data volume, show under `/`, as Finder shows them.
    #expect(root("/Users/me/Documents", mounted) == "/")
    #expect(root("/System/Volumes/Data/Users", mounted) == "/")
    #expect(root("/Volumes/Backup/a/b", mounted) == "/Volumes/Backup")
    #expect(root("/Volumes/Backup", mounted) == "/Volumes/Backup")
    #expect(root("/Users/me/mnt/s/docs", mounted) == "/Users/me/mnt/s")
    #expect(root("/Users/me/mnt", mounted) == "/")
    #expect(root("/", mounted) == "/")
    // Before the mount table is read, and for a volume not mounted now.
    #expect(root("/Volumes/Gone/a") == "/Volumes/Gone")
    #expect(root("/Volumes") == "/")
    #expect(root("/Users/me/mnt/s/docs") == "/")
    // Without case, as APFS compares names, spelled as the path spells it.
    #expect(root("/volumes/backup/a", mounted) == "/volumes/backup")
    #expect(root("/volumes/gone/a") == "/volumes/gone")
    #expect(root("/users/ME/mnt/S/docs", mounted) == "/users/ME/mnt/S")
    // A volume Finder doesn't show, mounted under `/Volumes`, roots its folders at `/`.
    let hidden = VolumeIdentity(
        device: "/dev/disk9s1", mountPoint: "/Volumes/h", kind: .local, isBrowsable: false)
    #expect(root("/Volumes/h/a", [startup, hidden]) == "/")
}

/// The root the path gives is too deep when a volume Finder doesn't show is mounted there: the
/// check adds the columns above it, each with the next folder selected, keeping the focus.
@MainActor @Test func aRootCheckedHigherThanThePathsAddsTheColumnsAboveIt() async {
    let hidden = VolumeIdentity(
        device: "/dev/disk9s1", mountPoint: "/Volumes/h", kind: .local, isBrowsable: false)
    let lister = GatedLister([
        "/": .batches([[folder("Volumes")]]), "/Volumes": .batches([[folder("h")]]),
        "/Volumes/h": .batches([[folder("docs")]]),
        "/Volumes/h/docs": .batches([[file("x.txt")]]),
    ])
    lister.releaseAll()
    let pane = Pane(
        location: Location(path: "/Volumes/h/docs"),
        service: ListingService(lister: lister, mountedVolumes: { [hidden] }),
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true,
        viewMode: .column)
    #expect(paths(pane) == ["/Volumes/h", "/Volumes/h/docs"])

    await trail(pane).rootChecked()

    #expect(paths(pane) == ["/", "/Volumes", "/Volumes/h", "/Volumes/h/docs"])
    #expect(trail(pane).focusedIndex == 3)
    #expect(pane.location == Location(path: "/Volumes/h/docs"))
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    #expect(
        trail(pane).columns.map { $0.pane.selection.cursor?.name } == ["Volumes", "h", "docs", nil])
}

/// The folder a column above keeps selected goes, removed or renamed: its column closes, as a
/// removed folder's does in any column.
@MainActor @Test func aRemovedOrRenamedFolderAColumnAboveKeepsClosesItsColumn() async {
    for patches: [FolderChange.Patch] in [
        [.remove(name: "docs")], [.remove(name: "docs"), .update(folder("papers"))],
    ] {
        // Any column: `docs` selected by a click.
        let any = await columnPane()
        select("docs", in: trail(any.pane).columns[1])
        await settle { trail(any.pane).columns.allSatisfy { $0.pane.state.isLoaded } }
        let anyParent = trail(any.pane).columns[1].pane
        anyParent.apply(.patches(patches), at: anyParent.location)
        await settle { !anyParent.state.names.contains("docs") }
        await drainMainQueue()
        // The column the trail built above `/r/docs`.
        let built = await columnPane(at: "/r/docs")
        let parent = trail(built.pane).columns[1].pane

        parent.apply(.patches(patches), at: parent.location)

        await settle { !parent.state.names.contains("docs") }
        await drainMainQueue()
        #expect(paths(any.pane) == ["/", "/r"], "\(patches)")
        #expect(paths(built.pane) == paths(any.pane), "\(patches)")
        #expect(trail(built.pane).focusedIndex == 1, "\(patches)")
    }
}

/// The root taken from the path is checked against the mount table off the main thread: a volume
/// mounted below `/` outside `/Volumes` drops the columns above it.
@MainActor @Test func aVolumeMountedOutsideVolumesStartsTheTrailAtItsMountPoint() async {
    let share = VolumeIdentity(device: "//me@nas.invalid/r", mountPoint: "/r", kind: .network)
    let lister = GatedLister(tree.mapValues { .batches([$0]) })
    lister.releaseAll()
    let pane = Pane(
        location: Location(path: "/r/docs"),
        service: ListingService(lister: lister, mountedVolumes: { [share] }),
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true,
        viewMode: .column)
    var changes = 0
    pane.onChange = { changes += 1 }

    await settle { paths(pane) == ["/r", "/r/docs"] }

    #expect(trail(pane).focusedIndex == 1)
    #expect(pane.location == Location(path: "/r/docs"))
    #expect(changes > 0)
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }
}

/// `/Users/me` is the home folder of `homeSettings`; `/Applications` is outside it.
private let homeTree: [String: [DirectoryEntry]] = [
    "/": [folder("Applications"), folder("Users")],
    "/Applications": [file("a.txt")],
    "/Users": [folder("me"), folder("Shared")],
    "/Users/me": [folder("docs"), folder("mnt")],
    "/Users/me/docs": [folder("sub"), file("x.txt")],
    "/Users/me/docs/sub": [file("deep.txt")],
    "/Users/me/mnt": [folder("s")],
    "/Users/me/mnt/s": [folder("a")],
    "/Users/me/mnt/s/a": [file("y.txt")],
]

/// Settings whose home folder is `/Users/me`, with columns starting there or not.
@MainActor
private func homeSettings(startAtHome: Bool = true) -> Settings {
    let settings = Settings(
        defaults: temporarySuite(in: FileManager.default.temporaryDirectory.path),
        home: "/Users/me")
    settings.columnsStartAtHome = startAtHome
    return settings
}

/// A focused column-mode pane at `path` over `homeTree`, with `settings`, its root checked
/// against `mounted` and every column loaded.
@MainActor
private func homePane(
    at path: String, settings: Settings = homeSettings(), mounted: [VolumeIdentity] = []
) async -> (pane: Pane, lister: GatedLister) {
    let lister = GatedLister(homeTree.mapValues { .batches([$0]) })
    lister.releaseAll()
    let pane = Pane(
        location: Location(path: path),
        service: ListingService(lister: lister, mountedVolumes: { mounted }),
        systemActions: StubSystemActions(), settings: settings, isFocused: true,
        viewMode: .column)
    await trail(pane).rootChecked()
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    return (pane, lister)
}

@MainActor @Test func theTrailOfAFolderInHomeStartsAtHomeWhenTheSettingIsOn() {
    func root(_ path: String, _ volumes: [VolumeIdentity] = [], home: String? = "/Users/me")
        -> String
    {
        ColumnTrail.root(
            of: Location(path: path), mountedVolumes: volumes, home: home.map(Location.init)
        ).path
    }
    let share = VolumeIdentity(
        device: "//me@nas.invalid/s", mountPoint: "/Users/me/mnt/s", kind: .network)
    let backup = VolumeIdentity(device: "/dev/disk5s1", mountPoint: "/Volumes/Backup", kind: .local)

    #expect(root("/Users/me/docs") == "/Users/me")
    #expect(root("/Users/me") == "/Users/me")
    // Without case, spelled as the path spells it.
    #expect(root("/users/ME/docs") == "/users/ME")
    // Folders outside home keep the volume's root.
    #expect(root("/Users") == "/")
    #expect(root("/Users/meat/docs") == "/")
    #expect(root("/Applications") == "/")
    #expect(root("/Volumes/Backup/a", [backup]) == "/Volumes/Backup")
    // A volume mounted inside home is the deeper root.
    #expect(root("/Users/me/mnt/s/a", [share]) == "/Users/me/mnt/s")
    #expect(root("/Users/me/mnt", [share]) == "/Users/me")
    // A home on a volume starts at home, below the volume's root.
    #expect(
        root("/Volumes/Backup/me/docs", [backup], home: "/Volumes/Backup/me")
            == "/Volumes/Backup/me")
    // With the setting off, the volume's root.
    #expect(root("/Users/me/docs", home: nil) == "/")
}

/// The home folder's trail starts at home on its first frame, and the check of its root keeps it
/// there; with the setting off it starts at `/`, as before.
@MainActor @Test func aTrailInHomeStartsAtHomeAndTheRootCheckKeepsIt() async {
    let on = await homePane(at: "/Users/me/docs")
    #expect(paths(on.pane) == ["/Users/me", "/Users/me/docs"])
    #expect(trail(on.pane).focusedIndex == 1)
    #expect(on.lister.calls.allSatisfy { $0.path.hasPrefix("/Users/me") })

    let off = await homePane(at: "/Users/me/docs", settings: homeSettings(startAtHome: false))
    #expect(paths(off.pane) == ["/", "/Users", "/Users/me", "/Users/me/docs"])

    let outside = await homePane(at: "/Applications")
    #expect(paths(outside.pane) == ["/", "/Applications"])

    let share = VolumeIdentity(
        device: "//me@nas.invalid/s", mountPoint: "/Users/me/mnt/s", kind: .network)
    let mounted = await homePane(at: "/Users/me/mnt/s/a", mounted: [share])
    #expect(paths(mounted.pane) == ["/Users/me/mnt/s", "/Users/me/mnt/s/a"])
}

/// ← in the home column does nothing, as at a volume's root; Cmd-↑ goes on up to the home
/// folder's parent, a step of the history, building that folder's trail from its root, with
/// home selected and its column open.
@MainActor @Test func leftAtTheHomeColumnDoesNothingAndCommandUpGoesToItsParent() async throws {
    let (pane, _) = await homePane(at: "/Users/me/docs")
    try press(KeyChord(.left), on: pane)
    #expect(trail(pane).focusedIndex == 0)
    var changes = 0
    pane.onChange = { changes += 1 }

    try press(KeyChord(.left), on: pane)

    #expect(trail(pane).focusedIndex == 0)
    #expect(changes == 0)
    #expect(paths(pane) == ["/Users/me", "/Users/me/docs"])

    try press(KeyChord(.up, modifiers: .command), on: pane)

    #expect(pane.location == Location(path: "/Users"))
    #expect(paths(pane).prefix(2) == ["/", "/Users"])
    #expect(trail(pane).focusedIndex == 1)
    #expect(trail(pane).focused.pane.selection.cursor == ExactName("me"))
    await settle { paths(pane) == ["/", "/Users", "/Users/me"] }

    // Above home, Cmd-↑ is ← again.
    try press(KeyChord(.up, modifiers: .command), on: pane)
    #expect(pane.location == Location(path: "/"))
    #expect(trail(pane).focusedIndex == 0)

    // Back to home focuses its column, which the trail from `/` shows, as Back does.
    try press(KeyChord("[", modifiers: .command), on: pane)
    try press(KeyChord("[", modifiers: .command), on: pane)

    #expect(pane.location == Location(path: "/Users/me"))
    #expect(paths(pane).prefix(3) == ["/", "/Users", "/Users/me"])
    #expect(trail(pane).focusedIndex == 2)
}

/// The path bar names `Users` and `/` above a home trail: a click there navigates, building that
/// folder's trail from its root.
@MainActor @Test func aPathBarClickAboveTheHomeColumnNavigates() async {
    let (pane, _) = await homePane(at: "/Users/me/docs")

    pane.showFolderAbove(Location(path: "/Users"), comingFrom: "me")

    #expect(pane.location == Location(path: "/Users"))
    #expect(paths(pane).prefix(2) == ["/", "/Users"])
    #expect(trail(pane).focused.pane.selection.cursor == ExactName("me"))
    #expect(pane.canGoBack)
}

/// Turning the setting off adds the columns above home to an open trail, and on again drops
/// them; the focused column and the columns right of it stay, and neither is a step.
@MainActor @Test func toggleTheSettingRestartsOpenTrailsAtTheirNewRoot() async {
    let settings = homeSettings()
    let (pane, _) = await homePane(at: "/Users/me/docs", settings: settings)
    select("sub", in: trail(pane).focused)
    await settle { paths(pane).count == 3 }
    let kept = trail(pane).columns.map(\.pane)

    settings.columnsStartAtHome = false
    await trail(pane).rootChecked()

    #expect(
        paths(pane) == ["/", "/Users", "/Users/me", "/Users/me/docs", "/Users/me/docs/sub"])
    #expect(trail(pane).focusedIndex == 3)
    #expect(trail(pane).columns.suffix(3).map(\.pane).elementsEqual(kept, by: ===))
    #expect(pane.location == Location(path: "/Users/me/docs"))
    #expect(!pane.canGoBack)
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    #expect(
        Array(trail(pane).columns.prefix(2).map { $0.pane.selection.cursor?.name })
            == ["Users", "me"])

    settings.columnsStartAtHome = true
    await trail(pane).rootChecked()

    #expect(paths(pane) == ["/Users/me", "/Users/me/docs", "/Users/me/docs/sub"])
    #expect(trail(pane).focusedIndex == 1)
    #expect(trail(pane).columns.map(\.pane).elementsEqual(kept, by: ===))
    #expect(!pane.canGoBack)
}

@MainActor @Test func switchingToColumnModeWithAFolderSelectedShowsItInTheNextColumn() async {
    let fixture = await columnPane(selecting: "docs")

    await settle { paths(fixture.pane) == ["/", "/r", "/r/docs"] }
    #expect(trail(fixture.pane).focusedIndex == 1)
}

@MainActor @Test func selectingAFolderAddsAColumnAndAFileAddsNone() async {
    let fixture = await columnPane()
    let first = trail(fixture.pane).columns[1]

    select("docs", in: first)
    #expect(paths(fixture.pane) == ["/", "/r", "/r/docs"])
    await settle { trail(fixture.pane).columns[2].pane.state.isLoaded }
    #expect(trail(fixture.pane).columns[2].pane.state.names == ["sub", "x.txt"])

    // A file opens no column: the folder's column goes, and the file's preview isn't one.
    select("a.txt", in: first)
    #expect(paths(fixture.pane) == ["/", "/r"])
}

/// The lister answers for the file's path too, so a column wrongly made for it shows up in the
/// trail instead of trapping in the lister.
@MainActor @Test func selectingAFileWithNoColumnToItsRightAddsNone() async {
    var folders = tree
    folders["/r/a.txt"] = []
    let fixture = PaneFixture(at: "/r", folders: folders)
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.setViewMode(.column)
    await settle { trail(fixture.pane).columns.allSatisfy { $0.pane.state.isLoaded } }

    select("a.txt", in: trail(fixture.pane).columns[1])
    await drainMainQueue()

    #expect(paths(fixture.pane) == ["/", "/r"])
}

/// A pane at `/p` in column mode over `/p`, holding a package `App.app` and a folder `docs`.
@MainActor
private func packageColumns() async -> PaneFixture {
    let fixture = PaneFixture(
        at: "/p",
        folders: [
            "/": [folder("p")], "/p": [package("App.app"), folder("docs")],
            "/p/App.app": [folder("Contents")],
            "/p/App.app/Contents": [file("Info.plist")], "/p/docs": [file("x.txt")],
        ])
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.setViewMode(.column)
    await settle { trail(fixture.pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    return fixture
}

@MainActor @Test func selectingAPackageAddsNoColumnPreviewsItAndRightDoesNothing() async throws {
    let fixture = await packageColumns()
    let first = trail(fixture.pane).columns[1]
    select("docs", in: first)
    #expect(paths(fixture.pane) == ["/", "/p", "/p/docs"])

    select("App.app", in: first)
    await drainMainQueue()
    #expect(paths(fixture.pane) == ["/", "/p"])
    #expect(trail(fixture.pane).preview?.location == Location(path: "/p/App.app"))
    #expect(trail(fixture.pane).preview?.entry == package("App.app"))

    try press(KeyChord(.right), on: fixture.pane)
    #expect(paths(fixture.pane) == ["/", "/p"])
    #expect(trail(fixture.pane).focusedIndex == 1)
    #expect(fixture.actions.openedFiles.isEmpty)
}

/// Opt-↓ moves ten rows, not to the last row, and the columns right of the selection wait for the
/// pause like any held key (0094-column-open-delay.md).
@MainActor @Test func optionDownInAColumnWaitsForThePauseBeforeOpeningTheNewSelection()
    async throws
{
    let clock = ManualClock()
    let names = (0..<14).map { String(format: "d%02d", $0) }
    var folders: [String: [DirectoryEntry]] = ["/": [folder("m")], "/m": names.map { folder($0) }]
    for name in names { folders["/m/\(name)"] = [file("x.txt")] }
    let fixture = PaneFixture(at: "/m", folders: folders)
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.setViewMode(.column)
    let pane = fixture.pane
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    pane.columnOpenClock = clock
    select("d00", in: trail(pane).columns[1])
    #expect(paths(pane) == ["/", "/m", "/m/d00"])

    try press(KeyChord(.down, modifiers: .option), on: pane)

    #expect(trail(pane).columns[1].pane.selection.cursor == ExactName("d10"))
    #expect(paths(pane) == ["/", "/m"])
    await settle { clock.waitingSleeps == 1 }
    clock.advance(by: ColumnTrail.openDelay)
    await settle { paths(pane) == ["/", "/m", "/m/d10"] }
}

/// A package selected by keys waits for the pause, as a file does, then previews and still adds
/// no column; Show Package Contents opens its column at once, since it is a command.
@MainActor @Test func aPackageSelectedByKeysPreviewsAfterThePauseAndShowContentsOpensAtOnce()
    async throws
{
    let clock = ManualClock()
    let fixture = await packageColumns()
    fixture.pane.columnOpenClock = clock
    let pane = fixture.pane
    select("docs", in: trail(pane).columns[1])
    #expect(paths(pane) == ["/", "/p", "/p/docs"])

    try press(KeyChord(.up), on: pane)

    #expect(trail(pane).columns[1].pane.selection.cursor == ExactName("App.app"))
    #expect(paths(pane) == ["/", "/p"])
    #expect(trail(pane).preview == nil)
    await settle { clock.waitingSleeps == 1 }
    clock.advance(by: ColumnTrail.openDelay)
    await settle { trail(pane).preview?.location == Location(path: "/p/App.app") }
    #expect(paths(pane) == ["/", "/p"])

    try press(KeyChord(.down), on: pane)
    try press(KeyChord(.up), on: pane)
    let binding = try #require(
        AppCommands.bindings.first { $0.command == NavigationCommands.showPackageContents })
    binding.run(CommandContext(pane: pane.commandPane))

    #expect(paths(pane) == ["/", "/p", "/p/App.app"])
    #expect(trail(pane).focusedIndex == 2)
    clock.advance(by: ColumnTrail.openDelay)
    // Finder selects nothing in the package, even once its rows land.
    await settle { trail(pane).columns[2].pane.state.isLoaded }
    for _ in 0..<3 { await drainMainQueue() }
    #expect(paths(pane) == ["/", "/p", "/p/App.app"])
    #expect(trail(pane).columns[2].pane.selection.isEmpty)
}

@MainActor @Test func showPackageContentsAddsThePackagesColumnAndMovesIntoItUntilAnotherSelection()
    async throws
{
    let fixture = await packageColumns()
    let first = trail(fixture.pane).columns[1]
    select("App.app", in: first)
    let binding = try #require(
        AppCommands.bindings.first { $0.command == NavigationCommands.showPackageContents })

    binding.run(CommandContext(pane: fixture.pane.commandPane))

    #expect(paths(fixture.pane) == ["/", "/p", "/p/App.app"])
    #expect(trail(fixture.pane).focusedIndex == 2)
    #expect(trail(fixture.pane).preview == nil)
    await settle { trail(fixture.pane).columns[2].pane.state.isLoaded }
    select("Contents", in: trail(fixture.pane).columns[2])
    #expect(paths(fixture.pane) == ["/", "/p", "/p/App.app", "/p/App.app/Contents"])

    // A change in the package's own column keeps the package's column while it stays selected.
    first.pane.reload()
    await settle { first.pane.state.isLoaded }
    #expect(paths(fixture.pane).prefix(3) == ["/", "/p", "/p/App.app"])

    select("docs", in: first)
    #expect(paths(fixture.pane) == ["/", "/p", "/p/docs"])
    select("App.app", in: first)
    #expect(paths(fixture.pane) == ["/", "/p"])
}

@MainActor @Test func selectingAFolderTruncatesTheColumnsToItsRight() async {
    let fixture = await columnPane()
    let first = trail(fixture.pane).columns[1]
    select("docs", in: first)
    await settle { trail(fixture.pane).columns[2].pane.state.isLoaded }
    select("sub", in: trail(fixture.pane).columns[2])
    #expect(paths(fixture.pane) == ["/", "/r", "/r/docs", "/r/docs/sub"])

    select("other", in: first)

    #expect(paths(fixture.pane) == ["/", "/r", "/r/other"])
    await settle { trail(fixture.pane).columns[2].pane.state.isLoaded }
    #expect(trail(fixture.pane).columns[2].pane.state.names == ["o.txt"])
}

@MainActor @Test func truncatedColumnsCancelTheirLoadsAndReleaseTheirWatches() async {
    let fixture = PaneFixture(at: "/r", folders: tree, held: true)
    fixture.lister.release("/")
    fixture.lister.release("/r")
    fixture.lister.release("/r/docs")
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.setViewMode(.column)
    await settle { trail(fixture.pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    let first = trail(fixture.pane).columns[1]
    select("docs", in: first)
    await settle { trail(fixture.pane).columns[2].pane.state.isLoaded }
    select("sub", in: trail(fixture.pane).columns[2])
    let docs = trail(fixture.pane).columns[2].pane
    let sub = trail(fixture.pane).columns[3].pane
    let docsMonitor = StubMonitor()
    let subMonitor = StubMonitor()
    docs.monitor = docsMonitor
    sub.monitor = subMonitor
    #expect(await fixture.lister.waitForCall("/r/docs/sub"))

    select("a.txt", in: first)
    fixture.lister.release("/r/docs/sub")
    #expect(await fixture.lister.waitForFinished(4))
    await drainMainQueue()

    #expect(paths(fixture.pane) == ["/", "/r"])
    #expect(docsMonitor.stopCount == 1)
    #expect(subMonitor.stopCount == 1)
    #expect(docs.monitor == nil && sub.monitor == nil)
    // The held load was cancelled, so its listing never reached the column.
    #expect(sub.state.isLoading)

    // A monitor that finishes starting after its column went is stopped at once.
    let late = StubMonitor()
    sub.monitor = late
    #expect(late.stopCount == 1)
    #expect(sub.monitor == nil)
}

@MainActor @Test func rightMovesIntoTheSelectedFolderAndLeftBackToItsColumn() async throws {
    let fixture = await columnPane()
    let pane = fixture.pane
    select("docs", in: trail(pane).columns[1])
    await settle { trail(pane).columns[2].pane.state.isLoaded }

    try press(KeyChord(.right), on: pane)

    #expect(trail(pane).focusedIndex == 2)
    #expect(pane.location == Location(path: "/r/docs"))
    // Moving into a column with nothing selected selects its first row.
    #expect(trail(pane).focused.pane.selection.cursor == ExactName("sub"))
    #expect(paths(pane) == ["/", "/r", "/r/docs", "/r/docs/sub"])

    try press(KeyChord(.left), on: pane)

    #expect(trail(pane).focusedIndex == 1)
    #expect(pane.location == Location(path: "/r"))
    #expect(paths(pane) == ["/", "/r", "/r/docs", "/r/docs/sub"])
}

@MainActor @Test func rightOnAFileDoesNothing() async throws {
    let fixture = await columnPane(selecting: "a.txt")

    try press(KeyChord(.right), on: fixture.pane)

    #expect(trail(fixture.pane).focusedIndex == 1)
    #expect(paths(fixture.pane) == ["/", "/r"])
    #expect(trail(fixture.pane).preview?.location == Location(path: "/r/a.txt"))
}

@MainActor
@Test(arguments: [KeyChord(.left), KeyChord(.up, modifiers: .command)])
func leftOrCommandUpMovesToTheParentsColumnAndDoesNothingAtTheRoot(chord: KeyChord) async throws {
    let fixture = await columnPane(at: "/r/docs")
    let pane = fixture.pane
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    let columns = trail(pane).columns.map(\.pane)
    var changes = 0
    pane.onChange = { changes += 1 }

    try press(chord, on: pane)

    #expect(trail(pane).focusedIndex == 1)
    #expect(pane.location == Location(path: "/r"))
    #expect(trail(pane).focused.pane.selection.cursor == ExactName("docs"))
    try press(chord, on: pane)
    #expect(trail(pane).focusedIndex == 0)
    #expect(changes == 2)

    // The first column is the volume's root: there is nothing left of it, as in Finder.
    try press(chord, on: pane)

    #expect(trail(pane).focusedIndex == 0)
    #expect(changes == 2)
    #expect(trail(pane).columns.map(\.pane).elementsEqual(columns, by: ===))
    #expect(paths(pane) == ["/", "/r", "/r/docs"])
}

/// `ListingService` starts a `.focused` load before every waiting normal one whose volume is
/// known (its own tests check the order), so a column's load jumps the queue by asking for it.
@MainActor @Test func theFocusedColumnsLoadJumpsTheQueue() async throws {
    let lister = GatedLister(tree.mapValues { .batches([$0]) })
    lister.releaseAll()
    let pane = Pane(
        location: Location(path: "/r/docs"), service: ListingService(lister: lister),
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true)
    await settle { pane.state.isLoaded }
    pane.setViewMode(.column)
    #expect(trail(pane).columns[2].pane.load?.priority == .focused)
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }

    // A column for a selected folder isn't focused; a column ← moves to is, once it lists again.
    select("sub", in: trail(pane).columns[2])
    try press(KeyChord(.left), on: pane)
    trail(pane).focused.pane.reload()

    #expect(paths(pane) == ["/", "/r", "/r/docs", "/r/docs/sub"])
    #expect(trail(pane).columns[3].pane.load?.priority == .visible)
    #expect(trail(pane).columns[1].pane.load?.priority == .focused)
}

@MainActor @Test func anUnfocusedPanesColumnsLoadAtNormalPriority() async {
    let fixture = await columnPane()

    #expect(trail(fixture.pane).focused.pane.load?.priority == .visible)
}

@MainActor @Test func switchingBackToListKeepsTheSelectedEntry() async throws {
    let fixture = await columnPane()
    let pane = fixture.pane
    select("docs", in: trail(pane).columns[1])
    await settle { trail(pane).columns[2].pane.state.isLoaded }
    try press(KeyChord(.right), on: pane)
    try press(KeyChord(.down), on: pane)
    #expect(trail(pane).focused.pane.selection.cursor == ExactName("x.txt"))

    try press(KeyChord("1", modifiers: .command), on: pane)

    #expect(pane.viewMode == .list)
    #expect(pane.columnTrail == nil)
    #expect(pane.commandPane === pane)
    #expect(pane.location == Location(path: "/r/docs"))
    await settle { pane.state.isLoaded }
    #expect(pane.selection.cursor == ExactName("x.txt"))
    #expect(pane.state.listing.map { pane.selection.rows(in: $0) } == [1])
}

@MainActor @Test func switchingBackToListClosesEveryColumn() async throws {
    let fixture = await columnPane(selecting: "docs")
    let pane = fixture.pane
    await settle { paths(pane).count == 3 }
    let monitors = trail(pane).columns.map { column in
        let monitor = StubMonitor()
        column.pane.monitor = monitor
        return monitor
    }

    pane.setViewMode(.list)

    #expect(monitors.map(\.stopCount) == [1, 1, 1])
}

@MainActor @Test func rowKeysAndTypeToSelectActOnTheFocusedColumn() async throws {
    let fixture = await columnPane()
    let pane = fixture.pane
    select("docs", in: trail(pane).columns[1])
    await settle { trail(pane).columns[2].pane.state.isLoaded }
    try press(KeyChord(.right), on: pane)

    try press(KeyChord(.down), on: pane)
    #expect(trail(pane).columns[2].pane.selection.cursor == ExactName("x.txt"))
    #expect(trail(pane).columns[1].pane.selection.cursor == ExactName("docs"))

    let typed = SelectionCommands.selectFirstRow(
        startingWith: "su", in: CommandContext(pane: pane.commandPane))
    #expect(typed)
    #expect(trail(pane).columns[2].pane.selection.cursor == ExactName("sub"))
    // A key-made selection opens its column once the keys pause.
    await settle { paths(pane) == ["/", "/r", "/r/docs", "/r/docs/sub"] }
}

@MainActor @Test func sortAndHiddenSettingsActOnTheFocusedColumn() async throws {
    let temp = try TemporaryFolder("ColumnTrailTests")
    let fixture = PaneFixture(at: "/r", folders: tree, settings: storedSettings(in: temp))
    await settle { fixture.pane.state.isLoaded }
    let pane = fixture.pane
    pane.setViewMode(.column)
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    select("docs", in: trail(pane).columns[1])
    await settle { trail(pane).columns[2].pane.state.isLoaded }
    try press(KeyChord(.right), on: pane)

    // Sort by Name again reverses the focused column only.
    try press(KeyChord("1", modifiers: [.control, .option]), on: pane)
    await settle { trail(pane).columns[2].pane.state.names == ["x.txt", "sub"] }
    #expect(trail(pane).columns[1].pane.sortAscending)
    // So do Reverse Sort Direction and Sort by Next Column.
    try press(KeyChord("p", modifiers: [.option, .command, .shift]), on: pane)
    await settle { trail(pane).columns[2].pane.state.names == ["sub", "x.txt"] }
    try press(KeyChord("p", modifiers: [.option, .command]), on: pane)
    await settle { trail(pane).columns[2].pane.sortColumn == .size }
    #expect(trail(pane).columns[1].pane.sortColumn == .name)
    #expect(trail(pane).columns[1].pane.sortAscending)
    try press(KeyChord("1", modifiers: [.control, .option]), on: pane)
    await settle { trail(pane).columns[2].pane.state.names == ["sub", "x.txt"] }
    try press(KeyChord("1", modifiers: [.control, .option]), on: pane)
    await settle { trail(pane).columns[2].pane.state.names == ["x.txt", "sub"] }

    try press(KeyChord(".", modifiers: [.command, .shift]), on: pane)
    await settle { trail(pane).columns[2].pane.state.names == ["x.txt", "sub", ".hidden"] }
}

@MainActor @Test func aColumnFilterNarrowsThatColumnOnly() async {
    let fixture = await columnPane()
    let pane = fixture.pane
    select("docs", in: trail(pane).columns[1])
    await settle { trail(pane).columns[2].pane.state.isLoaded }
    pane.columnTrail?.moveRight()

    pane.commandPane.setFilter("x")

    await settle { trail(pane).columns[2].pane.state.names == ["x.txt"] }
    #expect(trail(pane).columns[1].pane.state.names == ["a.txt", "docs", "other"])
}

@MainActor @Test func backInColumnModeStartsTheTrailAtAFolderLeftThatHasNoColumn() async throws {
    let fixture = await columnPane()
    let pane = fixture.pane
    select("docs", in: trail(pane).columns[1])
    await settle { trail(pane).columns[2].pane.state.isLoaded }
    try press(KeyChord(.right), on: pane)

    pane.navigate(to: Location(path: "/r/other"))
    #expect(paths(pane) == ["/", "/r", "/r/other"])
    #expect(pane.commandPane.canGoBack)

    try press(KeyChord("[", modifiers: .command), on: pane)

    #expect(paths(pane) == ["/", "/r", "/r/docs"])
    #expect(pane.location == Location(path: "/r/docs"))
    #expect(trail(pane).focused.pane.selection.cursor == ExactName("sub"))
}

/// Back, Forward and a navigation to a folder the trail doesn't show keep the columns of the
/// folders above it that the trail does show, from its root: the same panes, with their rows,
/// listing nothing again, each selecting the next folder on the new way down, as no step of its
/// selection history (0103-column-trail-from-the-root.md).
@MainActor @Test func aFolderOutsideTheTrailKeepsTheColumnsAboveItThatBothShow() async throws {
    let fixture = await columnPane(at: "/r/docs")
    let pane = fixture.pane
    let above = trail(pane).columns.prefix(2).map(\.pane)
    func listings(_ path: String) -> Int {
        fixture.lister.calls.filter { $0.path == path }.count
    }
    let root = listings("/")
    let parent = listings("/r")
    func expectKept(selecting name: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(
            trail(pane).columns.prefix(2).map(\.pane).elementsEqual(above, by: ===),
            sourceLocation: sourceLocation)
        #expect(
            above[1].selection == Selection([ExactName(name)], cursor: ExactName(name)),
            sourceLocation: sourceLocation)
        #expect(trail(pane).focusedIndex == 2, sourceLocation: sourceLocation)
    }

    // A sidebar click.
    pane.navigate(to: Location(path: "/r/other"))

    #expect(paths(pane) == ["/", "/r", "/r/other"])
    expectKept(selecting: "other")
    #expect(pane.history.backEntries.count == 1)
    await settle { trail(pane).focused.pane.state.isLoaded }

    try press(KeyChord("[", modifiers: .command), on: pane)

    #expect(paths(pane) == ["/", "/r", "/r/docs"])
    expectKept(selecting: "docs")
    #expect(!pane.canGoBack)
    await settle { trail(pane).focused.pane.state.isLoaded }

    try press(KeyChord("]", modifiers: .command), on: pane)

    #expect(paths(pane) == ["/", "/r", "/r/other"])
    expectKept(selecting: "other")
    #expect(!pane.canGoForward)
    #expect(!above[1].canUndoSelection)
    await trail(pane).rootChecked()
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    await drainMainQueue()
    #expect(listings("/") == root)
    #expect(listings("/r") == parent)
}

/// A kept column whose filter hides the next folder on the new way down loses the filter and
/// selects that folder, as a navigation clears a filter.
@MainActor @Test func aKeptColumnsFilterIsClearedAndTheNextFolderSelected() async {
    let fixture = await columnPane(at: "/r/docs")
    let pane = fixture.pane
    let parent = trail(pane).columns[1].pane
    parent.setFilter("doc")
    await settle { parent.state.names == ["docs"] }

    pane.navigate(to: Location(path: "/r/other"))

    #expect(trail(pane).columns[1].pane === parent)
    #expect(parent.filter.text.isEmpty)
    #expect(parent.selection == Selection([ExactName("other")], cursor: ExactName("other")))
    await settle { parent.state.names.contains("other") }
    #expect(paths(pane) == ["/", "/r", "/r/other"])
}

/// A folder the new trail starts at a different root for keeps no column, as a trail from home
/// and one outside it don't share one; trails from the same root keep the root's column.
@MainActor @Test func aTrailFromAnotherRootKeepsNoColumn() async {
    let (pane, _) = await homePane(at: "/Users/me/docs")
    let old = trail(pane).columns.map(\.pane)

    pane.navigate(to: Location(path: "/Applications"))

    #expect(paths(pane) == ["/", "/Applications"])
    #expect(!trail(pane).columns.contains { column in old.contains { $0 === column.pane } })

    let (fromRoot, _) = await homePane(
        at: "/Users/me/docs", settings: homeSettings(startAtHome: false))
    let rootColumn = trail(fromRoot).columns[0].pane

    fromRoot.navigate(to: Location(path: "/Applications"))

    #expect(paths(fromRoot) == ["/", "/Applications"])
    #expect(trail(fromRoot).columns[0].pane === rootColumn)
    #expect(rootColumn.selection.cursor == ExactName("Applications"))
    #expect(!rootColumn.isFocused)
    #expect(trail(fromRoot).focused.pane.isFocused)

    // Up to the root itself: its column is kept as the focused one.
    fromRoot.navigate(to: Location(path: "/"))

    #expect(paths(fromRoot) == ["/"])
    #expect(trail(fromRoot).focused.pane === rootColumn)
    #expect(rootColumn.isFocused)
    #expect(rootColumn.selection.isEmpty)
}

/// A navigation to a folder the trail shows, as a sidebar click on it, keeps that folder's
/// column too: it takes the keys with the name asked for selected, and the column that opens
/// for it is new.
@MainActor @Test func aNavigationToAFolderTheTrailShowsKeepsItsColumn() async {
    let fixture = await columnPane(at: "/r/docs/sub")
    let pane = fixture.pane
    let kept = trail(pane).columns.prefix(2).map(\.pane)

    pane.navigate(to: Location(path: "/r"), selecting: "other")

    #expect(paths(pane) == ["/", "/r", "/r/other"])
    #expect(trail(pane).columns.prefix(2).map(\.pane).elementsEqual(kept, by: ===))
    #expect(trail(pane).focusedIndex == 1)
    #expect(trail(pane).focused.pane === kept[1])
    #expect(kept[1].selection.cursor == ExactName("other"))
    #expect(pane.location == Location(path: "/r"))
    #expect(pane.history.backEntries.count == 1)
}

/// The folder the pane shows, its focused column's, is what History keeps in column view, as
/// the title Finder's Back follows: → and ← into another column are steps, and Back and Forward
/// to a folder the trail still shows move the focus there without building the trail again.
@MainActor @Test func movesBetweenColumnsAreStepsThatBackAndForwardRetrace() async throws {
    let fixture = await columnPane(selecting: "docs")
    let pane = fixture.pane
    await settle { paths(pane).count == 3 && trail(pane).columns[2].pane.state.isLoaded }
    #expect(!pane.canGoBack)

    try press(KeyChord(.right), on: pane)

    #expect(pane.location == Location(path: "/r/docs"))
    #expect(pane.commandPane.canGoBack)
    #expect(
        pane.history.backEntries
            == [History.Entry(location: Location(path: "/r"), selected: ExactName("docs"))])
    await settle { paths(pane) == ["/", "/r", "/r/docs", "/r/docs/sub"] }
    await settle { trail(pane).columns[3].pane.state.isLoaded }
    try press(KeyChord(.right), on: pane)
    await settle { trail(pane).focused.pane.selection.cursor == ExactName("deep.txt") }
    #expect(pane.history.backEntries.count == 2)
    let columns = trail(pane).columns.map(\.pane)
    let listings = fixture.lister.calls.count

    try press(KeyChord("[", modifiers: .command), on: pane)

    // Back to `docs`: its column takes the keys with `sub` selected, and `sub`'s column is the
    // last, with nothing selected, as `docs` showed it.
    #expect(trail(pane).columns.map(\.pane).elementsEqual(columns, by: ===))
    #expect(trail(pane).focusedIndex == 2)
    #expect(pane.location == Location(path: "/r/docs"))
    #expect(trail(pane).focused.pane.selection.cursor == ExactName("sub"))
    #expect(trail(pane).columns[3].pane.selection.isEmpty)
    #expect(pane.history.backEntries.count == 1)
    #expect(pane.canGoForward)

    try press(KeyChord("[", modifiers: .command), on: pane)

    #expect(trail(pane).focusedIndex == 1)
    #expect(pane.location == Location(path: "/r"))
    #expect(paths(pane) == ["/", "/r", "/r/docs"])
    #expect(trail(pane).columns[2].pane.selection.isEmpty)
    #expect(!pane.canGoBack)
    await drainMainQueue()
    #expect(fixture.lister.calls.count == listings)

    try press(KeyChord("]", modifiers: .command), on: pane)
    try press(KeyChord("]", modifiers: .command), on: pane)

    // Forward selects the entry remembered in each folder again.
    #expect(trail(pane).focusedIndex == 3)
    #expect(pane.location == Location(path: "/r/docs/sub"))
    #expect(trail(pane).focused.pane.selection.cursor == ExactName("deep.txt"))
    #expect(trail(pane).columns[2].pane.selection.cursor == ExactName("sub"))
    #expect(!pane.canGoForward)
    #expect(pane.history.backEntries.count == 2)

    try press(KeyChord(.left), on: pane)

    // ← is a step too, and it ends the way forward.
    #expect(
        pane.history.backEntries.last
            == History.Entry(
                location: Location(path: "/r/docs/sub"), selected: ExactName("deep.txt")))
    try press(KeyChord("[", modifiers: .command), on: pane)
    #expect(pane.location == Location(path: "/r/docs/sub"))
    #expect(trail(pane).focused.pane.selection.cursor == ExactName("deep.txt"))
}

/// A held ↓ through a column of folders keeps the focus in its column, so it makes no step,
/// however many columns open on the way.
@MainActor @Test func downThroughFoldersMakesNoStep() async throws {
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let pane = fixture.pane

    for _ in 0..<3 {
        try press(KeyChord(.down), on: pane)
        clock.advance(by: ColumnTrail.openDelay)
        await settle { trail(pane).columns.count == 3 }
    }

    #expect(paths(pane) == ["/", "/k", "/k/f3"])
    #expect(!pane.canGoBack)
}

/// A click on the folder selected in a column left of the focused one, which its column opens,
/// closes the columns right of that folder's, and leaves nothing selected in it, as in Finder.
@MainActor @Test func aPressOnTheSelectedFolderShowsOnlyItsColumnRightOfIt() async throws {
    let fixture = await columnPane(at: "/r/docs/sub")
    let pane = fixture.pane
    #expect(paths(pane) == ["/", "/r", "/r/docs", "/r/docs/sub"])
    select("deep.txt", in: trail(pane).columns[3])
    let first = trail(pane).columns[1]
    let docs = trail(pane).columns[2].pane

    trail(pane).focus(first)
    first.pane.pressSelectedFolder()

    #expect(paths(pane) == ["/", "/r", "/r/docs"])
    #expect(trail(pane).columns[2].pane === docs)
    #expect(docs.selection.isEmpty)
    #expect(trail(pane).focusedIndex == 1)
    #expect(first.pane.selection.cursor == ExactName("docs"))
    #expect(trail(pane).preview == nil)

    // A press on a selected file, or in the last column, closes nothing.
    select("x.txt", in: trail(pane).columns[2])
    #expect(trail(pane).preview?.location == Location(path: "/r/docs/x.txt"))
    trail(pane).columns[2].pane.pressSelectedFolder()
    #expect(paths(pane) == ["/", "/r", "/r/docs"])
    #expect(trail(pane).preview?.location == Location(path: "/r/docs/x.txt"))
}

/// The root check can find the root past the focused column, when ← moved the focus up before
/// the check landed. Moving the focus back is a correction of the trail, so it is no step.
@MainActor @Test func theRootCheckMovingTheFocusRecordsNoStep() async {
    let share = VolumeIdentity(
        device: "//me@nas.invalid/r/docs", mountPoint: "/r/docs", kind: .network)
    let lister = GatedLister(tree.mapValues { .batches([$0]) })
    lister.releaseAll()
    let pane = Pane(
        location: Location(path: "/r/docs"),
        service: ListingService(lister: lister, mountedVolumes: { [share] }),
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true,
        viewMode: .column)
    trail(pane).moveLeft()
    #expect(trail(pane).focusedIndex == 1)
    let back = pane.history.backEntries

    await trail(pane).rootChecked()

    #expect(paths(pane) == ["/r/docs"])
    #expect(trail(pane).focusedIndex == 0)
    #expect(pane.history.backEntries == back)
}

/// Open on a folder in a column the keys aren't in is one gesture: one step, from the column
/// that had them, so Back lands there and not on the column opened from.
@MainActor @Test func openOnAFolderInAnotherColumnIsOneStep() async {
    let fixture = await columnPane(at: "/r/docs/sub")
    let pane = fixture.pane
    #expect(trail(pane).focusedIndex == 3)
    select("deep.txt", in: trail(pane).columns[3])
    let back = pane.history.backEntries.count

    trail(pane).openFolder(from: trail(pane).columns[1].pane)

    #expect(trail(pane).focusedIndex == 2)
    #expect(pane.history.backEntries.count == back + 1)
    #expect(
        pane.history.backEntries.last
            == History.Entry(
                location: Location(path: "/r/docs/sub"), selected: ExactName("deep.txt")))
}

/// Show Package Contents on a package in a column the keys aren't in is one step likewise.
@MainActor @Test func showPackageContentsInAnotherColumnIsOneStep() async {
    let fixture = PaneFixture(
        at: "/root",
        folders: [
            "/": [folder("root")], "/root": [package("App.app"), folder("docs")],
            "/root/App.app": [folder("Contents")],
        ])
    let pane = fixture.pane
    await settle { pane.state.isLoaded }
    pane.setViewMode(.column)
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    let parent = trail(pane).columns[1].pane
    parent.select(Selection([ExactName("App.app")], cursor: ExactName("App.app")))
    trail(pane).focus(trail(pane).columns[0])
    let back = pane.history.backEntries.count

    parent.showPackageContents()

    #expect(paths(pane).last == "/root/App.app")
    #expect(pane.history.backEntries.count == back + 1)
}

/// A press that closes the column right of the pressed one clears that column's selection, which
/// is no step of its selection history: the press is the step, in the column it was made in.
@MainActor @Test func aPressShowingTheNextColumnAloneLeavesItsSelectionHistoryAlone() async {
    let fixture = await columnPane(at: "/r/docs/sub")
    let pane = fixture.pane
    let docs = trail(pane).columns[2].pane
    docs.select(Selection([ExactName("sub")], cursor: ExactName("sub")), recordingAs: nil)
    #expect(!docs.canUndoSelection)
    trail(pane).focus(trail(pane).columns[1])

    trail(pane).columns[1].pane.pressSelectedFolder()

    #expect(docs.selection.isEmpty)
    #expect(!docs.canUndoSelection)
}

@MainActor @Test func openOnAFolderInAColumnMovesIntoItsColumn() async throws {
    let fixture = await columnPane(selecting: "docs")
    let pane = fixture.pane
    await settle { paths(pane).count == 3 && trail(pane).columns[2].pane.state.isLoaded }

    try press(KeyChord(.down, modifiers: .command), on: pane)

    #expect(trail(pane).focusedIndex == 2)
    #expect(paths(pane) == ["/", "/r", "/r/docs", "/r/docs/sub"])
}

@MainActor @Test func aColumnWhoseLoadGoesSlowIsSlowAndKeepsTheTrail() async {
    var outcomes = tree.mapValues { GatedLister.Outcome.batches([$0]) }
    outcomes["/r/docs"] = .blockForever
    let lister = GatedLister(outcomes)
    lister.releaseAll()
    let clock = ManualClock()
    let pane = Pane(
        location: Location(path: "/r"), service: ListingService(lister: lister, clock: clock),
        systemActions: StubSystemActions(), settings: untouchedSettings())
    await settle { pane.state.isLoaded }
    pane.setViewMode(.column)
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    select("docs", in: trail(pane).columns[1])
    #expect(await lister.waitForCall("/r/docs"))
    var changes = 0
    pane.onChange = { changes += 1 }

    clock.advance(by: LoadTimeouts.slow)
    // The slow update reaches the main queue from the load's timer task, with nothing to wait on.
    try? await Task.sleep(for: .milliseconds(200))
    await drainMainQueue()

    #expect(trail(pane).columns[2].pane.state.isSlow)
    #expect(trail(pane).columns[2].pane.state.listing == nil)
    #expect(paths(pane) == ["/", "/r", "/r/docs"])
    #expect(trail(pane).focusedIndex == 1)
    #expect(changes == 1)
}

@MainActor @Test func backToAFolderWithNoColumnKeepsTheFocusedColumnsSort() async throws {
    let fixture = await columnPane(at: "/r/docs")
    let pane = fixture.pane
    pane.navigate(to: Location(path: "/r/other"))
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    try press(KeyChord("2", modifiers: [.control, .option]), on: pane)
    #expect(trail(pane).focused.pane.sortColumn == .size)

    try press(KeyChord("[", modifiers: .command), on: pane)

    #expect(paths(pane) == ["/", "/r", "/r/docs"])
    #expect(trail(pane).focused.pane.sortColumn == .size)
    #expect(trail(pane).focused.pane.load?.column == .size)
    // The columns kept above it take the sort too.
    #expect(trail(pane).columns.allSatisfy { $0.pane.sortColumn == .size })
}

@MainActor @Test func thePaneHoldsNoRowsInColumnModeAndSortsNothingOnAToggle() async throws {
    let temp = try TemporaryFolder("ColumnTrailTests")
    let fixture = PaneFixture(at: "/r/docs", folders: tree, settings: storedSettings(in: temp))
    await settle { fixture.pane.state.isLoaded }
    let pane = fixture.pane
    pane.setViewMode(.column)
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    #expect(pane.state.listing == nil)
    let sorts = pane.sortCount

    pane.settings.showHidden = true
    await settle { trail(pane).focused.pane.state.names.count == 3 }

    #expect(pane.sortCount == sorts)
    #expect(pane.state.listing == nil)
}

@MainActor @Test func aColumnFollowsAlwaysHideDSStore() async throws {
    let temp = try TemporaryFolder("ColumnTrailTests")
    let settings = storedSettings(in: temp)
    settings.showHidden = true
    let fixture = PaneFixture(
        at: "/r",
        folders: ["/": [folder("r")], "/r": [file("a"), file(".DS_Store"), file(".dot")]],
        settings: settings)
    await settle { fixture.pane.state.isLoaded }
    let pane = fixture.pane
    pane.setViewMode(.column)
    await settle { trail(pane).focused.pane.state.names == [".dot", "a"] }

    settings.hideDSStore = false

    await settle { trail(pane).focused.pane.state.names == [".dot", ".DS_Store", "a"] }
}

@MainActor @Test func switchingToColumnsStopsThePanesOwnLoadAndMonitor() async {
    let fixture = PaneFixture(at: "/r", folders: tree, held: true)
    let pane = fixture.pane
    let monitor = StubMonitor()
    pane.monitor = monitor
    #expect(await fixture.lister.waitForCall("/r"))

    pane.setViewMode(.column)
    fixture.lister.releaseAll()
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    #expect(await fixture.lister.waitForFinished(2))
    await drainMainQueue()

    #expect(monitor.stopCount == 1)
    #expect(pane.monitor == nil)
    #expect(pane.state.listing == nil)
}

@MainActor @Test func thePaneIgnoresFolderChangesInColumnMode() async {
    let fixture = await columnPane()
    let calls = fixture.lister.calls.count

    fixture.pane.apply(.relist, at: fixture.pane.location)

    #expect(await !fixture.lister.waitForCalls(calls + 1, timeout: 0.5))
    #expect(fixture.pane.state.listing == nil)
}

/// A navigation closes the columns of the folders the new trail doesn't run through, stopping
/// their loads and monitors; the columns above that both trails show stay, watched as before.
@MainActor @Test func aNavigationClosesTheColumnsItLeaves() async throws {
    let fixture = PaneFixture(at: "/r", folders: tree, held: true)
    for path in ["/", "/r", "/r/docs", "/r/other"] { fixture.lister.release(path) }
    let pane = fixture.pane
    await settle { pane.state.isLoaded }
    pane.setViewMode(.column)
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    select("docs", in: trail(pane).columns[1])
    await settle { trail(pane).columns[2].pane.state.isLoaded }
    select("sub", in: trail(pane).columns[2])
    #expect(await fixture.lister.waitForCall("/r/docs/sub"))
    let left = trail(pane).columns.map(\.pane)
    let monitors = left.map { column in
        let monitor = StubMonitor()
        column.monitor = monitor
        return monitor
    }

    // A sidebar click.
    pane.navigate(to: Location(path: "/r/other"))
    fixture.lister.release("/r/docs/sub")
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    #expect(await fixture.lister.waitForFinished(5))
    await drainMainQueue()

    #expect(paths(pane) == ["/", "/r", "/r/other"])
    #expect(monitors.map(\.stopCount) == [0, 0, 1, 1])
    #expect(trail(pane).columns.prefix(2).map(\.pane).elementsEqual(left.prefix(2), by: ===))
    // The held load was cancelled, so its listing never reached the closed column.
    #expect(left[3].state.isLoading)

    let other = StubMonitor()
    trail(pane).focused.pane.monitor = other
    try press(KeyChord("[", modifiers: .command), on: pane)

    // Back to `/r`, which the trail shows, selects `docs` there again, closing `other`'s column.
    #expect(other.stopCount == 1)
    #expect(paths(pane) == ["/", "/r", "/r/docs"])
}

@MainActor @Test func goToFolderInColumnModeStartsTheTrailAtTheFolder() async {
    let fixture = await columnPane()
    let pane = fixture.pane
    var finished = false

    pane.goToFolder(Location(path: "/r/docs")) { error in
        #expect(error == nil)
        finished = true
    }
    await settle { finished }

    #expect(paths(pane) == ["/", "/r", "/r/docs"])
    #expect(pane.location == Location(path: "/r/docs"))
    #expect(pane.canGoBack)
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }
}

@MainActor @Test func openOnALinkToAFolderInAColumnStartsTheTrailAtTheLink() async throws {
    let link = DirectoryEntry(
        name: "link", type: .symbolicLink, size: nil, modified: testDate, isHidden: false,
        isDataless: false)
    var folders = tree
    folders["/r"] = [folder("docs"), link]
    folders["/r/link"] = [file("l.txt")]
    let fixture = PaneFixture(at: "/r", folders: folders)
    let pane = fixture.pane
    await settle { pane.state.isLoaded }
    pane.setViewMode(.column)
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    select("link", in: trail(pane).columns[1])

    try press(KeyChord(.down, modifiers: .command), on: pane)

    await settle { paths(pane) == ["/", "/r", "/r/link"] }
    await settle { trail(pane).focused.pane.state.names == ["l.txt"] }
    #expect(fixture.actions.openedFiles.isEmpty)
}

@MainActor @Test func aColumnFocusedAgainAsksForFocusedLoads() async throws {
    let fixture = await columnPane()
    let pane = fixture.pane
    pane.didGainFocus()
    select("docs", in: trail(pane).columns[1])
    await settle { trail(pane).columns[2].pane.state.isLoaded }
    #expect(trail(pane).columns[2].pane.load?.priority == .visible)
    try press(KeyChord(.right), on: pane)
    try press(KeyChord(.left), on: pane)
    try press(KeyChord(.right), on: pane)
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }

    trail(pane).columns[2].pane.reload()
    trail(pane).columns[1].pane.reload()

    #expect(trail(pane).columns[2].pane.load?.priority == .focused)
    #expect(trail(pane).columns[1].pane.load?.priority == .visible)
}

@MainActor @Test func aColumnGoesCachedRefreshingThenOfflineLikeAListPane() async {
    let share = VolumeIdentity(
        device: "//me@nas.invalid/n", mountPoint: "/Volumes/n", kind: .network)
    let listedAt = Date(timeIntervalSinceReferenceDate: 700_000_000)
    let cache = ListingCache(store: nil)
    for (path, entries) in [
        "/Volumes/n": [folder("docs"), file("a.txt")], "/Volumes/n/docs": [file("x.txt")],
    ] {
        await cache.insert(
            ListingCache.Folder(entries: entries, listedAt: listedAt), at: path, on: share)
    }
    // The share stops answering: no read of it ever returns.
    let lister = GatedLister(["/Volumes/n": .blockForever, "/Volumes/n/docs": .blockForever])
    lister.releaseAll()
    let clock = ManualClock()
    let service = ListingService(
        lister: lister, clock: clock, volumeOf: { _ in share }, cache: cache)
    let pane = Pane(
        location: Location(path: "/Volumes/n"), service: service,
        systemActions: StubSystemActions(),
        settings: untouchedSettings(), isFocused: true)
    await settle { pane.state.isCachedRefreshing }

    pane.setViewMode(.column)
    let first = trail(pane).columns[0]
    await settle { first.pane.state.isCachedRefreshing }
    #expect(first.pane.state.names == ["a.txt", "docs"])
    select("docs", in: first)
    await settle { paths(pane) == ["/Volumes/n", "/Volumes/n/docs"] }
    let second = trail(pane).columns[1]
    await settle { second.pane.state.isCachedRefreshing }
    #expect(second.pane.state.names == ["x.txt"])

    clock.advance(by: LoadTimeouts.giveUp)
    await settle { first.pane.state.isOffline && second.pane.state.isOffline }
    #expect(first.pane.state.names == ["a.txt", "docs"])
    #expect(first.pane.state.listedAt == listedAt)
    #expect(second.pane.state.names == ["x.txt"])
    #expect(paths(pane) == ["/Volumes/n", "/Volumes/n/docs"])
}

@MainActor @Test func cachedRowsThatLackTheSelectedFolderKeepTheColumnsToTheRight() async throws {
    let share = VolumeIdentity(
        device: "//me@nas.invalid/n", mountPoint: "/Volumes/n", kind: .network)
    let cache = ListingCache(store: nil)
    // Cached before docs was made, so the parent's cached rows don't have it.
    await cache.insert(
        ListingCache.Folder(entries: [file("a.txt")], listedAt: testDate), at: "/Volumes/n",
        on: share)
    let lister = GatedLister([
        "/Volumes/n": .blockForever, "/Volumes/n/docs": .batches([[file("x.txt")]]),
    ])
    lister.release("/Volumes/n/docs")
    let clock = ManualClock()
    let service = ListingService(
        lister: lister, clock: clock, volumeOf: { _ in share }, cache: cache)
    let pane = Pane(
        location: Location(path: "/Volumes/n/docs"), service: service,
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true)
    await settle { pane.state.isLoaded }
    pane.setViewMode(.column)
    await settle { trail(pane).focused.pane.state.isLoaded }

    try press(KeyChord(.left), on: pane)
    let parent = trail(pane).columns[0].pane
    await settle { parent.state.isCachedRefreshing }
    #expect(paths(pane) == ["/Volumes/n", "/Volumes/n/docs"])

    clock.advance(by: LoadTimeouts.slow)
    await settle { parent.state.isSlow }
    #expect(paths(pane) == ["/Volumes/n", "/Volumes/n/docs"])

    clock.advance(by: LoadTimeouts.giveUp - LoadTimeouts.slow)
    await settle { parent.state.isOffline }
    #expect(paths(pane) == ["/Volumes/n", "/Volumes/n/docs"])
}

@MainActor @Test func focusingAColumnMovesTheKeysThereWithoutChangingTheColumns() async throws {
    let fixture = await columnPane()
    let pane = fixture.pane
    select("docs", in: trail(pane).columns[1])
    await settle { trail(pane).columns[2].pane.state.isLoaded }
    var changes = 0
    pane.onChange = { changes += 1 }

    trail(pane).focus(trail(pane).columns[2])

    #expect(trail(pane).focusedIndex == 2)
    #expect(pane.location == Location(path: "/r/docs"))
    #expect(pane.commandPane === trail(pane).columns[2].pane)
    #expect(paths(pane) == ["/", "/r", "/r/docs"])
    #expect(trail(pane).columns[2].pane.selection.isEmpty)
    #expect(changes == 1)

    trail(pane).focus(trail(pane).columns[2])

    #expect(changes == 1)
}

@MainActor @Test func oneSelectedFileInTheLastColumnIsPreviewedFromItsListing() async throws {
    let fixture = await columnPane()
    let first = trail(fixture.pane).columns[1]
    let calls = fixture.lister.calls.count
    #expect(trail(fixture.pane).preview == nil)

    select("a.txt", in: first)

    let preview = try #require(trail(fixture.pane).preview)
    let listing = try #require(first.pane.state.listing)
    let row = try #require(listing.row(named: "a.txt"))
    #expect(preview.location == Location(path: "/r/a.txt"))
    #expect(preview.entry == file("a.txt"))
    #expect(preview.kind == listing.kind(atRow: row))
    // The preview is neither a column nor a pane, and reads nothing.
    #expect(paths(fixture.pane) == ["/", "/r"])
    await drainMainQueue()
    #expect(fixture.lister.calls.count == calls)
}

@MainActor @Test func aFolderSeveralRowsOrNoneSelectedClearThePreview() async throws {
    let fixture = await columnPane()
    let first = trail(fixture.pane).columns[1]
    select("a.txt", in: first)
    #expect(trail(fixture.pane).preview != nil)

    select("docs", in: first)
    #expect(trail(fixture.pane).preview == nil)

    select("a.txt", in: first)
    #expect(trail(fixture.pane).preview != nil)
    first.pane.select(
        Selection([ExactName("a.txt"), ExactName("other")], cursor: ExactName("a.txt")))
    #expect(trail(fixture.pane).preview == nil)

    select("a.txt", in: first)
    #expect(trail(fixture.pane).preview != nil)
    first.pane.select(Selection())
    #expect(trail(fixture.pane).preview == nil)
}

@MainActor @Test func thePreviewFollowsTheLastColumnOnly() async throws {
    let fixture = await columnPane()
    let pane = fixture.pane
    select("docs", in: trail(pane).columns[1])
    await settle { trail(pane).columns[2].pane.state.isLoaded }

    select("x.txt", in: trail(pane).columns[2])

    #expect(trail(pane).preview?.location == Location(path: "/r/docs/x.txt"))
    #expect(paths(pane) == ["/", "/r", "/r/docs"])

    // Choosing another folder on the left drops the column the file was in, and its preview.
    select("other", in: trail(pane).columns[1])

    #expect(trail(pane).preview == nil)
}

@MainActor @Test func aPatchedEntryUpdatesThePreviewAndARemovedOneClearsIt() async throws {
    let fixture = await columnPane()
    let first = trail(fixture.pane).columns[1].pane
    select("a.txt", in: trail(fixture.pane).columns[1])

    first.apply(.patches([.update(file("a.txt", size: 5))]), at: first.location)
    await settle { trail(fixture.pane).preview?.entry.size == 5 }

    first.apply(.patches([.remove(name: "a.txt")]), at: first.location)
    await settle { trail(fixture.pane).preview == nil }
    #expect(paths(fixture.pane) == ["/", "/r"])
}

@MainActor @Test func closingTheTrailClearsThePreview() async throws {
    let fixture = await columnPane(selecting: "a.txt")
    let trail = trail(fixture.pane)
    #expect(trail.preview != nil)

    fixture.pane.setViewMode(.list)

    #expect(trail.preview == nil)
}

/// Telling a link to a folder from a link to a file takes a read, which the preview never makes,
/// and Open treats a link to a folder as its folder; so no link is previewed. A socket or another
/// special file is, as in Finder.
@MainActor @Test func aLinkShowsNoPreviewAndASpecialFileDoes() async throws {
    func entry(_ name: String, _ type: DirectoryEntry.FileType) -> DirectoryEntry {
        DirectoryEntry(
            name: name, type: type, size: nil, modified: testDate, isHidden: false,
            isDataless: false)
    }
    var folders = tree
    folders["/r"] = [folder("docs"), entry("link", .symbolicLink), entry("socket", .other)]
    let fixture = PaneFixture(at: "/r", folders: folders)
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.setViewMode(.column)
    await settle { trail(fixture.pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    let first = trail(fixture.pane).columns[1]

    select("socket", in: first)
    #expect(trail(fixture.pane).preview?.location == Location(path: "/r/socket"))

    select("link", in: first)
    #expect(trail(fixture.pane).preview == nil)
    #expect(paths(fixture.pane) == ["/", "/r"])
}

// MARK: - Opening a column once the keys pause

/// `/k` holds folders `f0` to `f10` and a file `z.txt`; each folder holds a folder `in` and files
/// `m.txt` and `n.txt`. `/k/z.txt` lists `y.txt` once a patch makes `z.txt` a folder.
private let keyTree: [String: [DirectoryEntry]] = {
    var folders: [String: [DirectoryEntry]] = ["/": [folder("k")], "/k/z.txt": [file("y.txt")]]
    folders["/k"] = (0...10).map { folder("f\($0)") } + [file("z.txt")]
    for index in 0...10 {
        folders["/k/f\(index)"] = [folder("in"), file("m.txt"), file("n.txt")]
        folders["/k/f\(index)/in"] = [file("deep.txt")]
    }
    return folders
}()

/// A focused pane at `/k` in column mode, waiting out its column-open pause on `clock`, with
/// `f0` selected as a click selects it and its column loaded.
@MainActor
private func keyedPane(clock: ManualClock) async -> PaneFixture {
    let fixture = PaneFixture(at: "/k", folders: keyTree)
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.columnOpenClock = clock
    fixture.pane.setViewMode(.column)
    await settle { trail(fixture.pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    select("f0", in: trail(fixture.pane).columns[1])
    await settle { trail(fixture.pane).columns.last?.pane.state.isLoaded == true }
    return fixture
}

/// Lets cancelled waits finish, so the clock counts only the waits still running.
@MainActor
private func drainWaits() async {
    for _ in 0..<3 { await drainMainQueue() }
}

@MainActor @Test func tenFastDownPressesOpenOnlyTheLastFoldersColumnAfterThePause() async throws {
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let pane = fixture.pane
    #expect(paths(pane) == ["/", "/k", "/k/f0"])

    for _ in 0..<10 {
        try press(KeyChord(.down), on: pane)
        clock.advance(by: ColumnTrail.openDelay - .milliseconds(1))
    }

    // The selection moves at once and the stale column goes; the new one waits.
    #expect(trail(pane).columns[1].pane.selection.cursor == ExactName("f10"))
    #expect(paths(pane) == ["/", "/k"])
    await settle { clock.waitingSleeps == 1 }

    clock.advance(by: .milliseconds(1))

    await settle { paths(pane) == ["/", "/k", "/k/f10"] }
    #expect(trail(pane).focusedIndex == 1)
    let skipped = (1...9).map { "/k/f\($0)" }
    #expect(!fixture.lister.calls.contains { skipped.contains($0.path) })
}

@MainActor @Test func cmdOptDownSelectsTheLastRowAndItsColumnOpensOnlyAfterThePause() async throws {
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let pane = fixture.pane

    try press(KeyChord(.down, modifiers: [.command, .option]), on: pane)

    #expect(trail(pane).columns[1].pane.selection.cursor == ExactName("z.txt"))
    #expect(paths(pane) == ["/", "/k"])
    await settle { clock.waitingSleeps == 1 }
    clock.advance(by: ColumnTrail.openDelay)
    await drainWaits()
    #expect(clock.waitingSleeps == 0)
    #expect(!fixture.lister.calls.contains { $0.path == "/k/f10" })
}

@MainActor @Test func aClickOpensTheFoldersColumnAtOnce() async throws {
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let first = trail(fixture.pane).columns[1].pane
    let listing = try #require(first.state.listing)
    let row = try #require(listing.row(named: "f3"))

    first.select(
        rows: IndexSet(integer: row), cursor: ExactName("f3"), anchor: ExactName("f3"),
        as: .press(1))

    #expect(paths(fixture.pane) == ["/", "/k", "/k/f3"])
    await drainWaits()
    #expect(clock.waitingSleeps == 0)
}

@MainActor @Test func rightArrowOpensAWaitingFoldersColumnAtOnceAndMovesIntoIt() async throws {
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let pane = fixture.pane
    try press(KeyChord(.down), on: pane)
    #expect(paths(pane) == ["/", "/k"])

    try press(KeyChord(.right), on: pane)

    #expect(paths(pane) == ["/", "/k", "/k/f1"])
    #expect(trail(pane).focusedIndex == 2)
    await drainWaits()
    #expect(clock.waitingSleeps == 0)
}

@MainActor @Test func leftArrowCancelsAWaitingColumn() async throws {
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let pane = fixture.pane
    try press(KeyChord(.down), on: pane)
    await settle { clock.waitingSleeps == 1 }

    try press(KeyChord(.left), on: pane)
    clock.advance(by: ColumnTrail.openDelay)
    // A patch to the column it left reports a change, which doesn't start the wait again.
    let column = trail(pane).columns[1].pane
    column.apply(.patches([.update(folder("new"))]), at: column.location)
    await settle { column.state.names.contains("new") }
    clock.advance(by: ColumnTrail.openDelay)
    await drainWaits()

    #expect(paths(pane) == ["/", "/k"])
    #expect(column.selection.cursor == ExactName("f1"))
    #expect(clock.waitingSleeps == 0)
    #expect(!fixture.lister.calls.contains { $0.path == "/k/f1" })
}

@MainActor @Test func closingThePaneOrSwitchingToTheListCancelsAWaitingColumn() async throws {
    let leaves: [@MainActor (Pane) -> Void] = [{ $0.close() }, { $0.setViewMode(.list) }]
    for leave in leaves {
        let clock = ManualClock()
        let fixture = await keyedPane(clock: clock)
        let pane = fixture.pane
        try press(KeyChord(.down), on: pane)
        await settle { clock.waitingSleeps == 1 }

        leave(pane)
        clock.advance(by: ColumnTrail.openDelay)
        await drainWaits()

        #expect(clock.waitingSleeps == 0)
        #expect(!fixture.lister.calls.contains { $0.path == "/k/f1" })
    }
}

@MainActor @Test func thePreviewOfAFileReachedByKeysShowsAfterThePause() async throws {
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let pane = fixture.pane
    try press(KeyChord(.right), on: pane)
    // → selects the first row, the folder `in`, and opens its column at once.
    #expect(paths(pane) == ["/", "/k", "/k/f0", "/k/f0/in"])

    try press(KeyChord(.down), on: pane)

    #expect(paths(pane) == ["/", "/k", "/k/f0"])
    #expect(trail(pane).preview == nil)
    clock.advance(by: ColumnTrail.openDelay)
    await settle { trail(pane).preview?.location == Location(path: "/k/f0/m.txt") }

    try press(KeyChord(.down), on: pane)

    #expect(trail(pane).preview == nil)
    clock.advance(by: ColumnTrail.openDelay)
    await settle { trail(pane).preview?.location == Location(path: "/k/f0/n.txt") }
}

@MainActor @Test func typeToSelectAndSelectLastWaitForThePauseToo() async throws {
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let pane = fixture.pane

    let typed = SelectionCommands.selectFirstRow(
        startingWith: "f5", in: CommandContext(pane: pane.commandPane))
    #expect(typed)
    #expect(paths(pane) == ["/", "/k"])
    clock.advance(by: ColumnTrail.openDelay)
    await settle { paths(pane) == ["/", "/k", "/k/f5"] }

    try press(KeyChord(.end), on: pane)
    #expect(paths(pane) == ["/", "/k"])
    clock.advance(by: ColumnTrail.openDelay)
    await settle { trail(pane).preview?.location == Location(path: "/k/z.txt") }
}

/// Selects `name`'s row alone in `pane` as a click does, keeping the anchor when the click lands
/// on the row already selected, as the table reports it.
@MainActor
private func click(_ name: String, in pane: Pane) throws {
    let listing = try #require(pane.state.listing)
    let row = try #require(listing.row(named: name))
    let isSelected = pane.selection.cursor == ExactName(name)
    pane.select(
        rows: IndexSet(integer: row), cursor: ExactName(name),
        anchor: isSelected ? pane.selection.anchor : ExactName(name), as: .press(1))
}

@MainActor @Test func aClickOnTheRowTheKeysLeftOpensItsColumnAtOnce() async throws {
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let pane = fixture.pane
    try press(KeyChord(.down), on: pane)
    await settle { clock.waitingSleeps == 1 }
    try press(KeyChord(.left), on: pane)
    let column = trail(pane).columns[1].pane

    try click("f1", in: column)

    #expect(paths(pane) == ["/", "/k", "/k/f1"])
}

@MainActor @Test func aClickOnAnotherRowDuringTheWaitOpensOnlyItsColumn() async throws {
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let pane = fixture.pane
    try press(KeyChord(.down), on: pane)
    await settle { clock.waitingSleeps == 1 }

    try click("f3", in: trail(pane).columns[1].pane)
    #expect(paths(pane) == ["/", "/k", "/k/f3"])
    clock.advance(by: ColumnTrail.openDelay)
    await drainWaits()

    #expect(paths(pane) == ["/", "/k", "/k/f3"])
    #expect(clock.waitingSleeps == 0)
    #expect(!fixture.lister.calls.contains { $0.path == "/k/f1" })
}

@MainActor @Test func removingTheWaitingFolderOpensWhatTheSelectionHoldsOnceTheKeysPause()
    async throws
{
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let pane = fixture.pane
    let first = trail(pane).columns[1].pane
    try press(KeyChord(.down), on: pane)
    await settle { clock.waitingSleeps == 1 }

    // A rename arrives as the old name's removal and the new name's update.
    first.apply(.patches([.remove(name: "f1"), .update(folder("g1"))]), at: first.location)
    await settle { !first.state.names.contains("f1") }
    #expect(paths(pane) == ["/", "/k"])
    clock.advance(by: ColumnTrail.openDelay)
    await drainWaits()

    // The columns follow whatever the selection holds now, and the removed folder never lists.
    let listing = try #require(first.state.listing)
    if let row = first.selection.cursorRow(in: listing), listing[row].type == .directory,
        first.selection.rows(in: listing) == IndexSet(integer: row)
    {
        await settle { paths(pane) == ["/", "/k", "/k/\(listing[row].name)"] }
    } else {
        #expect(paths(pane) == ["/", "/k"])
    }
    #expect(!fixture.lister.calls.contains { $0.path == "/k/f1" })
}

@MainActor @Test func rightArrowOnAFileShowsItsWaitingPreviewAtOnce() async throws {
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let pane = fixture.pane
    try press(KeyChord(.right), on: pane)
    try press(KeyChord(.down), on: pane)
    #expect(trail(pane).preview == nil)

    try press(KeyChord(.right), on: pane)

    #expect(trail(pane).preview?.location == Location(path: "/k/f0/m.txt"))
    #expect(trail(pane).focusedIndex == 2)
    await drainWaits()
    #expect(clock.waitingSleeps == 0)
}

/// Once the columns follow a key-made selection, a patch that changes what it asks for is
/// followed at once: only a new selection by keys waits.
@MainActor @Test func aPatchAfterTheWaitIsFollowedAtOnce() async throws {
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let pane = fixture.pane
    let first = trail(pane).columns[1].pane
    try press(KeyChord(.end), on: pane)
    clock.advance(by: ColumnTrail.openDelay)
    await settle { trail(pane).preview?.location == Location(path: "/k/z.txt") }

    first.apply(.patches([.update(folder("z.txt"))]), at: first.location)

    await settle { paths(pane) == ["/", "/k", "/k/z.txt"] }
    #expect(clock.waitingSleeps == 0)
}

// MARK: - Reading the preview's info

/// An `ItemInfo` whose dates are `seconds` and twice that after `testDate`, tagged `tags`.
private func info(_ seconds: Double, tags: [String] = []) -> ItemInfo {
    ItemInfo(
        created: testDate.addingTimeInterval(seconds),
        lastOpened: testDate.addingTimeInterval(2 * seconds), tags: tags)
}

@MainActor @Test func aPreviewReadsItsFilesInfoOffTheMainThread() async throws {
    let fixture = await columnPane()
    let reader = GatedItemInfoReader(["/r/a.txt": info(1, tags: ["Red"])])
    fixture.pane.itemInfoReader = reader

    select("a.txt", in: trail(fixture.pane).columns[1])

    #expect(trail(fixture.pane).preview?.info == .reading)
    #expect(await reader.waitForCall("/r/a.txt"))
    #expect(reader.calls.map(\.onMainThread) == [false])
    #expect(reader.calls.map(\.onBlockingCallThread) == [true])
    reader.releaseAll()
    await settle { trail(fixture.pane).preview?.info == .read(info(1, tags: ["Red"])) }
}

/// A file replaced under its name, as a save by rename replaces it, is read again; it shows
/// what was read of it until then.
@MainActor @Test func aChangedFileIsReadAgain() async throws {
    let fixture = await columnPane()
    let reader = GatedItemInfoReader(["/r/a.txt": info(1)])
    reader.releaseAll()
    fixture.pane.itemInfoReader = reader
    let first = trail(fixture.pane).columns[1].pane
    select("a.txt", in: trail(fixture.pane).columns[1])
    await settle { trail(fixture.pane).preview?.info == .read(info(1)) }

    first.apply(.patches([.update(file("a.txt", size: 5))]), at: first.location)

    await settle { reader.calls.count == 2 }
    #expect(trail(fixture.pane).preview?.entry.size == 5)
    #expect(trail(fixture.pane).preview?.info == .read(info(1)))
    #expect(await reader.waitForFinished(2))
    for _ in 0..<3 { await drainMainQueue() }
    #expect(trail(fixture.pane).preview?.info == .read(info(1)))
}

/// A failed read is tried again only once the file's entry changes, not on a patch to another.
@MainActor @Test func aFailedReadIsReadAgainOnlyOnceItsEntryChanges() async throws {
    let fixture = await columnPane()
    let reader = GatedItemInfoReader(["/r/a.txt": nil])
    reader.releaseAll()
    fixture.pane.itemInfoReader = reader
    let first = trail(fixture.pane).columns[1].pane
    select("a.txt", in: trail(fixture.pane).columns[1])
    await settle { trail(fixture.pane).preview?.info == .failed }

    first.apply(.patches([.update(file("b.txt"))]), at: first.location)
    await settle { first.state.names.contains("b.txt") }
    for _ in 0..<3 { await drainMainQueue() }
    #expect(reader.calls.count == 1)

    first.apply(.patches([.update(file("a.txt", size: 5))]), at: first.location)

    await settle { reader.calls.count == 2 }
    #expect(await reader.waitForFinished(2))
    await settle { trail(fixture.pane).preview?.entry.size == 5 }
    for _ in 0..<3 { await drainMainQueue() }
    #expect(trail(fixture.pane).preview?.info == .failed)
}

@MainActor @Test func aPatchToAnotherEntryKeepsThePreviewsRead() async throws {
    let fixture = await columnPane()
    let reader = GatedItemInfoReader(["/r/a.txt": info(1)])
    reader.releaseAll()
    fixture.pane.itemInfoReader = reader
    let first = trail(fixture.pane).columns[1].pane
    select("a.txt", in: trail(fixture.pane).columns[1])
    await settle { trail(fixture.pane).preview?.info == .read(info(1)) }

    first.apply(.patches([.update(file("b.txt"))]), at: first.location)

    await settle { first.state.names.contains("b.txt") }
    for _ in 0..<3 { await drainMainQueue() }
    #expect(trail(fixture.pane).preview?.info == .read(info(1)))
    #expect(reader.calls.count == 1)
}

@MainActor @Test func aPackagesPreviewReadsItsInfoToo() async throws {
    var folders = tree
    folders["/r"] = [package("App.app")]
    let fixture = PaneFixture(at: "/r", folders: folders)
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.setViewMode(.column)
    await settle { trail(fixture.pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    let reader = GatedItemInfoReader(["/r/App.app": info(3)])
    reader.releaseAll()
    fixture.pane.itemInfoReader = reader

    select("App.app", in: trail(fixture.pane).columns[1])

    await settle { trail(fixture.pane).preview?.info == .read(info(3)) }
}

@MainActor @Test func aFailedReadShowsAsFailed() async throws {
    let fixture = await columnPane()
    let reader = GatedItemInfoReader(["/r/a.txt": nil])
    reader.releaseAll()
    fixture.pane.itemInfoReader = reader

    select("a.txt", in: trail(fixture.pane).columns[1])

    await settle { trail(fixture.pane).preview?.info == .failed }
}

@MainActor @Test func aPreviewReachedByKeysReadsOnlyOnceTheKeysPause() async throws {
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let pane = fixture.pane
    let reader = GatedItemInfoReader(["/k/f0/m.txt": info(1), "/k/f0/n.txt": info(2)])
    reader.releaseAll()
    pane.itemInfoReader = reader
    try press(KeyChord(.right), on: pane)
    try press(KeyChord(.down), on: pane)
    try press(KeyChord(.down), on: pane)

    await drainMainQueue()
    #expect(reader.calls.isEmpty)
    clock.advance(by: ColumnTrail.openDelay)

    await settle { trail(pane).preview?.info == .read(info(2)) }
    #expect(reader.calls.map(\.path) == ["/k/f0/n.txt"])
}

@MainActor @Test func aReadForAFileNoLongerPreviewedIsDropped() async throws {
    let fixture = await keyedPane(clock: ManualClock())
    let pane = fixture.pane
    let reader = GatedItemInfoReader(["/k/f0/m.txt": info(1), "/k/f0/n.txt": info(2)])
    pane.itemInfoReader = reader
    let column = trail(pane).columns[2]
    try click("m.txt", in: column.pane)
    #expect(await reader.waitForCall("/k/f0/m.txt"))

    try click("n.txt", in: column.pane)
    reader.release("/k/f0/m.txt")
    #expect(await reader.waitForFinished(1))
    for _ in 0..<3 { await drainMainQueue() }

    #expect(trail(pane).preview?.location == Location(path: "/k/f0/n.txt"))
    #expect(trail(pane).preview?.info == .reading)
    reader.release("/k/f0/n.txt")
    await settle { trail(pane).preview?.info == .read(info(2)) }
}

/// `/k/f0` in column view, with `/k/f0/m.txt` previewed and read, its preview waiting out its
/// hold on `clock` and reading with `reader`, which holds `/k/f0/n.txt`'s read until released.
@MainActor
private func previewedM(holdingOn clock: ManualClock, reader: GatedItemInfoReader) async throws
    -> PaneFixture
{
    let fixture = await keyedPane(clock: ManualClock())
    let pane = fixture.pane
    pane.previewHoldClock = clock
    pane.itemInfoReader = reader
    reader.release("/k/f0/m.txt")
    try click("m.txt", in: trail(pane).columns[2].pane)
    await settle { trail(pane).shownPreview?.info == .read(info(1)) }
    return fixture
}

/// Selecting another file keeps the file shown before on screen until the new one's info is
/// read, so its rows show neither empty nor the old file's dates (0095-preview-metadata.md).
@MainActor @Test func anotherFileShowsOnlyOnceItsInfoIsRead() async throws {
    let reader = GatedItemInfoReader(["/k/f0/m.txt": info(1), "/k/f0/n.txt": info(2)])
    let fixture = try await previewedM(holdingOn: ManualClock(), reader: reader)
    let pane = fixture.pane
    let m = try #require(trail(pane).shownPreview)
    #expect(m.location == Location(path: "/k/f0/m.txt"))

    try click("n.txt", in: trail(pane).columns[2].pane)

    #expect(trail(pane).preview?.location == Location(path: "/k/f0/n.txt"))
    #expect(trail(pane).preview?.info == .reading)
    #expect(trail(pane).shownPreview == m)
    reader.release("/k/f0/n.txt")
    await settle { trail(pane).shownPreview?.info == .read(info(2)) }
    #expect(trail(pane).shownPreview == trail(pane).preview)
}

/// The first file previewed has nothing to keep on screen: it shows once its info is read.
@MainActor @Test func theFirstFileShowsOnlyOnceItsInfoIsRead() async throws {
    let fixture = await keyedPane(clock: ManualClock())
    let pane = fixture.pane
    pane.previewHoldClock = ManualClock()
    let reader = GatedItemInfoReader(["/k/f0/m.txt": info(1)])
    pane.itemInfoReader = reader

    try click("m.txt", in: trail(pane).columns[2].pane)

    #expect(trail(pane).preview?.info == .reading)
    #expect(trail(pane).shownPreview == nil)
    reader.release("/k/f0/m.txt")
    await settle { trail(pane).shownPreview?.info == .read(info(1)) }
}

/// A read that takes longer than the hold, as one on a slow share does, shows the new file with
/// empty rows once the hold ends, counted from the first selection it held through.
@MainActor @Test func aSlowReadShowsTheFileWithoutItsInfoOnceTheHoldEnds() async throws {
    let clock = ManualClock()
    let reader = GatedItemInfoReader(["/k/f0/m.txt": info(1), "/k/f0/n.txt": info(2)])
    let fixture = try await previewedM(holdingOn: clock, reader: reader)
    let pane = fixture.pane
    let column = trail(pane).columns[2].pane
    let m = trail(pane).shownPreview

    try click("n.txt", in: column)
    clock.advance(by: ColumnTrail.previewHold - .milliseconds(1))
    await drainMainQueue()
    #expect(trail(pane).shownPreview == m)

    clock.advance(by: .milliseconds(1))

    await settle { trail(pane).shownPreview?.location == Location(path: "/k/f0/n.txt") }
    #expect(trail(pane).shownPreview?.info == .reading)
    reader.releaseAll()
}

@MainActor @Test func anotherSelectionDuringTheHoldKeepsItsDeadline() async throws {
    let clock = ManualClock()
    let reader = GatedItemInfoReader(["/k/f0/m.txt": info(1), "/k/f0/n.txt": info(2)])
    let fixture = await keyedPane(clock: ManualClock())
    let pane = fixture.pane
    pane.previewHoldClock = clock
    pane.itemInfoReader = reader
    let column = trail(pane).columns[2].pane
    try click("m.txt", in: column)
    clock.advance(by: ColumnTrail.previewHold / 2)

    try click("n.txt", in: column)
    clock.advance(by: ColumnTrail.previewHold / 2)

    await settle { trail(pane).shownPreview?.location == Location(path: "/k/f0/n.txt") }
    reader.releaseAll()
}

/// A folder, or no file, ends the hold at once: the preview goes, as before.
@MainActor @Test func aFolderSelectedDuringTheHoldDropsThePreviewAtOnce() async throws {
    let reader = GatedItemInfoReader(["/k/f0/m.txt": info(1), "/k/f0/n.txt": info(2)])
    let clock = ManualClock()
    let fixture = try await previewedM(holdingOn: clock, reader: reader)
    let pane = fixture.pane
    let column = trail(pane).columns[2].pane
    try click("n.txt", in: column)
    #expect(trail(pane).shownPreview?.location == Location(path: "/k/f0/m.txt"))

    try click("in", in: column)

    #expect(trail(pane).preview == nil)
    #expect(trail(pane).shownPreview == nil)
    await drainMainQueue()
    #expect(clock.waitingSleeps == 0)
    reader.releaseAll()
}

/// List mode, a navigation and closing the pane during the hold end it with the trail: nothing
/// waits on the hold's clock afterwards.
@MainActor @Test func closingTheTrailDuringTheHoldEndsItsWait() async throws {
    for closing in ["list mode", "navigation", "pane close"] {
        let reader = GatedItemInfoReader(["/k/f0/m.txt": info(1), "/k/f0/n.txt": info(2)])
        let clock = ManualClock()
        let fixture = try await previewedM(holdingOn: clock, reader: reader)
        let pane = fixture.pane
        let trail = trail(pane)
        try click("n.txt", in: trail.columns[2].pane)
        #expect(trail.shownPreview?.location == Location(path: "/k/f0/m.txt"), "\(closing)")
        await settle { clock.waitingSleeps == 1 }

        switch closing {
        case "list mode": pane.setViewMode(.list)
        case "navigation": pane.navigate(to: Location(path: "/k/f1"))
        default: pane.close()
        }

        #expect(trail.shownPreview == nil, "\(closing)")
        await drainMainQueue()
        #expect(clock.waitingSleeps == 0, "\(closing)")
        reader.releaseAll()
    }
}

/// Dylan saw the preview flash blank between files reached by ↓: the keys cleared it while they
/// paused, and the next file was held with nothing to show before it. Now the file shown stays
/// while the keys pause and while the next file's info is read.
@MainActor @Test func arrowsBetweenFilesKeepTheShownPreviewUntilTheNextIsRead() async throws {
    let reader = GatedItemInfoReader(["/k/f0/m.txt": info(1), "/k/f0/n.txt": info(2)])
    let fixture = try await previewedM(holdingOn: ManualClock(), reader: reader)
    let pane = fixture.pane
    let clock = ManualClock()
    pane.columnOpenClock = clock
    let m = try #require(trail(pane).shownPreview)

    trail(pane).columns[2].pane.moveSelection(by: 1)

    #expect(trail(pane).preview == nil)
    #expect(trail(pane).shownPreview == m)
    await settle { clock.waitingSleeps == 1 }
    clock.advance(by: ColumnTrail.openDelay)
    await settle { trail(pane).preview?.location == Location(path: "/k/f0/n.txt") }
    #expect(trail(pane).shownPreview == m)
    reader.release("/k/f0/n.txt")
    await settle { trail(pane).shownPreview?.info == .read(info(2)) }
}

/// ↓ then ↑ back to the file shown keeps it, with what was read of it, until it is read again.
@MainActor @Test func arrowsBackToTheShownFileKeepItsRowsUntilItIsReadAgain() async throws {
    let reader = GatedItemInfoReader(["/k/f0/m.txt": info(1), "/k/f0/n.txt": info(2)])
    let fixture = try await previewedM(holdingOn: ManualClock(), reader: reader)
    let pane = fixture.pane
    let clock = ManualClock()
    pane.columnOpenClock = clock
    let m = try #require(trail(pane).shownPreview)
    let column = trail(pane).columns[2].pane

    column.moveSelection(by: 1)
    column.moveSelection(by: -1)
    #expect(trail(pane).shownPreview == m)
    await settle { clock.waitingSleeps == 1 }
    clock.advance(by: ColumnTrail.openDelay)
    await settle { trail(pane).preview?.location == Location(path: "/k/f0/m.txt") }

    #expect(trail(pane).shownPreview == m)
    await settle { trail(pane).shownPreview?.info == .read(info(1)) }
}

/// ↑ from a file to a folder keeps the file shown until the keys pause and the folder's column
/// opens in its place.
@MainActor @Test func arrowsFromAFileToAFolderKeepThePreviewUntilTheColumnOpens() async throws {
    let reader = GatedItemInfoReader(["/k/f0/m.txt": info(1)])
    let fixture = try await previewedM(holdingOn: ManualClock(), reader: reader)
    let pane = fixture.pane
    let clock = ManualClock()
    pane.columnOpenClock = clock
    let m = try #require(trail(pane).shownPreview)

    trail(pane).columns[2].pane.moveSelection(by: -1)

    #expect(trail(pane).shownPreview == m)
    await settle { clock.waitingSleeps == 1 }
    clock.advance(by: ColumnTrail.openDelay)
    await settle { paths(pane) == ["/", "/k", "/k/f0", "/k/f0/in"] }
    #expect(trail(pane).shownPreview == nil)
}

/// Keys in a column left of the preview's drop the preview's column at once, and the preview
/// with it: its file is no longer in the trail.
@MainActor @Test func arrowsInAColumnLeftOfThePreviewDropItAtOnce() async throws {
    let reader = GatedItemInfoReader(["/k/f0/m.txt": info(1)])
    let fixture = try await previewedM(holdingOn: ManualClock(), reader: reader)
    let pane = fixture.pane
    pane.columnOpenClock = ManualClock()

    trail(pane).columns[1].pane.moveSelection(by: 1)

    #expect(paths(pane) == ["/", "/k"])
    #expect(trail(pane).shownPreview == nil)
}

@MainActor @Test func aReadLandingAfterTheTrailClosesIsDropped() async throws {
    for closing in ["list mode", "navigation", "pane close"] {
        let fixture = await columnPane()
        let pane = fixture.pane
        let reader = GatedItemInfoReader(["/r/a.txt": info(1)])
        pane.itemInfoReader = reader
        let trail = trail(pane)
        select("a.txt", in: trail.columns[1])
        #expect(await reader.waitForCall("/r/a.txt"), "\(closing)")

        switch closing {
        case "list mode": pane.setViewMode(.list)
        case "navigation": pane.navigate(to: Location(path: "/r/other"))
        default: pane.close()
        }
        reader.releaseAll()
        #expect(await reader.waitForFinished(1), "\(closing)")
        for _ in 0..<3 { await drainMainQueue() }

        #expect(trail.preview == nil, "\(closing)")
    }
}

@MainActor @Test func aDatalessFileGetsNoRead() async throws {
    var folders = tree
    folders["/r"] = [
        DirectoryEntry(
            name: "cloud.txt", type: .regular, size: 9, modified: testDate, isHidden: false,
            isDataless: true)
    ]
    let fixture = PaneFixture(at: "/r", folders: folders)
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.setViewMode(.column)
    await settle { trail(fixture.pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    let reader = GatedItemInfoReader([:])
    fixture.pane.itemInfoReader = reader

    select("cloud.txt", in: trail(fixture.pane).columns[1])
    for _ in 0..<3 { await drainMainQueue() }

    #expect(trail(fixture.pane).preview?.location == Location(path: "/r/cloud.txt"))
    #expect(trail(fixture.pane).preview?.info == .unread)
    #expect(reader.calls.isEmpty)
}

/// A focused pane on a share at `/Volumes/n` in column mode, showing cached rows that list `a.txt`
/// while `lister` lists it again on `clock`.
@MainActor
private func cachedSharePane(lister: GatedLister, clock: ManualClock) async -> Pane {
    let share = VolumeIdentity(
        device: "//me@nas.invalid/n", mountPoint: "/Volumes/n", kind: .network)
    let cache = ListingCache(store: nil)
    await cache.insert(
        ListingCache.Folder(entries: [file("a.txt")], listedAt: testDate), at: "/Volumes/n",
        on: share)
    let service = ListingService(
        lister: lister, clock: clock, volumeOf: { _ in share }, cache: cache)
    let pane = Pane(
        location: Location(path: "/Volumes/n"), service: service,
        systemActions: StubSystemActions(),
        settings: untouchedSettings(), isFocused: true)
    await settle { pane.state.isCachedRefreshing }
    pane.setViewMode(.column)
    await settle { trail(pane).columns[0].pane.state.isCachedRefreshing }
    return pane
}

/// A share that hasn't answered might not: no read waits on it while its rows are cached, slow
/// or offline.
@MainActor @Test func aFileOnAShareThatDoesntAnswerGetsNoRead() async throws {
    let clock = ManualClock()
    let pane = await cachedSharePane(
        lister: GatedLister(["/Volumes/n": .blockForever]), clock: clock)
    let reader = GatedItemInfoReader([:])
    pane.itemInfoReader = reader
    let first = trail(pane).columns[0]

    select("a.txt", in: first)
    #expect(trail(pane).preview?.info == .unread)

    clock.advance(by: LoadTimeouts.giveUp)
    await settle { first.pane.state.isOffline }
    for _ in 0..<3 { await drainMainQueue() }

    #expect(trail(pane).preview?.location == Location(path: "/Volumes/n/a.txt"))
    #expect(trail(pane).preview?.info == .unread)
    #expect(reader.calls.isEmpty)
}

@MainActor @Test func aFileIsReadOnceItsShareAnswers() async throws {
    let lister = GatedLister(["/Volumes/n": .batches([[file("a.txt")]])])
    let pane = await cachedSharePane(lister: lister, clock: ManualClock())
    let reader = GatedItemInfoReader(["/Volumes/n/a.txt": info(4)])
    reader.releaseAll()
    pane.itemInfoReader = reader
    select("a.txt", in: trail(pane).columns[0])
    #expect(trail(pane).preview?.info == .unread)

    lister.release("/Volumes/n")

    await settle { trail(pane).preview?.info == .read(info(4)) }
}

/// A focused pane at `/r` in column mode, waiting out its column-open pause on `clock`, with
/// `docs` selected by a click and its column still loading: the lister holds `/r/docs` until the
/// test releases it.
@MainActor
private func loadingDocsColumn(clock: ManualClock = ManualClock()) async -> PaneFixture {
    let fixture = PaneFixture(at: "/r", folders: tree, held: true)
    fixture.lister.release("/")
    fixture.lister.release("/r")
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.columnOpenClock = clock
    fixture.pane.setViewMode(.column)
    await settle { trail(fixture.pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    select("docs", in: trail(fixture.pane).columns[1])
    #expect(await fixture.lister.waitForCall("/r/docs"))
    return fixture
}

@MainActor @Test func rightIntoALoadingColumnSelectsItsFirstRowWhenTheRowsLand() async throws {
    let clock = ManualClock()
    let fixture = await loadingDocsColumn(clock: clock)
    let pane = fixture.pane
    try press(KeyChord(.right), on: pane)
    #expect(trail(pane).focusedIndex == 2)
    #expect(trail(pane).focused.pane.selection.isEmpty)

    fixture.lister.release("/r/docs")
    fixture.lister.release("/r/docs/sub")

    await settle { trail(pane).columns[2].pane.selection.cursor == ExactName("sub") }
    // Not a key-made selection: the folder in row 0 opens its column at once, with no wait for
    // the keys to pause, as → does when the rows are already there.
    #expect(paths(pane) == ["/", "/r", "/r/docs", "/r/docs/sub"])
    #expect(trail(pane).focusedIndex == 2)
    await drainWaits()
    #expect(clock.waitingSleeps == 0)
}

/// A selection in the loading column, even one cleared again, ← out of it, a click in another
/// column, the pane losing the keys, or navigating before its rows land each give up selecting
/// its first row.
@MainActor @Test func aSelectionLeftAFocusChangeOrNavigationBeforeTheRowsLandCancelsIt()
    async throws
{
    let cancels: [(String, @MainActor (Pane) throws -> Void)] = [
        ("select", { pane in select("x.txt", in: trail(pane).columns[2]) }),
        (
            "deselect",
            { pane in
                select("x.txt", in: trail(pane).columns[2])
                trail(pane).columns[2].pane.select(Selection())
            }
        ),
        ("blur", { pane in pane.didLoseFocus() }),
        ("left", { pane in try press(KeyChord(.left), on: pane) }),
        ("focus", { pane in trail(pane).focus(trail(pane).columns[1]) }),
        ("navigate", { pane in pane.navigate(to: Location(path: "/r/other")) }),
    ]
    for (name, cancel) in cancels {
        let fixture = await loadingDocsColumn()
        let pane = fixture.pane
        try press(KeyChord(.right), on: pane)
        let docs = trail(pane).focused.pane

        try cancel(pane)
        fixture.lister.release("/r/docs")
        fixture.lister.release("/r/other")
        await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }
        await drainMainQueue()

        if name == "navigate" {
            #expect(paths(pane) == ["/", "/r", "/r/other"])
            #expect(trail(pane).focused.pane.selection.isEmpty)
        } else {
            #expect(paths(pane) == ["/", "/r", "/r/docs"], "after \(name)")
        }
        #expect(
            docs.selection.cursor == (name == "select" ? ExactName("x.txt") : nil),
            "after \(name)")
    }
}

/// The first batch of a large folder is the first entries read, sorted among themselves only,
/// so its first row isn't the folder's; → waits for the full listing.
@MainActor @Test func rightIntoALargeLoadingFolderSelectsTheFullListingsFirstRow() async throws {
    let late = (100..<400).map { file("m\($0)") }
    let early = (100..<200).map { file("a\($0)") }
    let lister = GatedLister([
        "/": .batches([[folder("r")]]), "/r": .batches([[folder("big")]]),
        "/r/big": .batches([late, early]),
    ])
    lister.release("/")
    lister.release("/r")
    let pane = Pane(
        location: Location(path: "/r"), service: ListingService(lister: lister),
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true)
    await settle { pane.state.isLoaded }
    pane.setViewMode(.column)
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    select("big", in: trail(pane).columns[1])
    #expect(await lister.waitForCall("/r/big"))
    try press(KeyChord(.right), on: pane)
    let big = trail(pane).focused.pane

    lister.release("/r/big")

    await settle { big.state.isLoaded }
    await drainMainQueue()
    #expect(big.selection.cursor == ExactName("a100"))
}

/// Rows that land empty give up the wait, so a file added later isn't selected.
@MainActor @Test func rightIntoALoadingFolderThatTurnsOutEmptySelectsNothingLater() async throws {
    var folders = tree
    folders["/r"] = [folder("empty")]
    folders["/r/empty"] = []
    let fixture = PaneFixture(at: "/r", folders: folders, held: true)
    fixture.lister.release("/")
    fixture.lister.release("/r")
    let pane = fixture.pane
    await settle { pane.state.isLoaded }
    pane.setViewMode(.column)
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    select("empty", in: trail(pane).columns[1])
    #expect(await fixture.lister.waitForCall("/r/empty"))
    try press(KeyChord(.right), on: pane)
    let empty = trail(pane).focused.pane

    fixture.lister.release("/r/empty")
    await settle { empty.state.isLoaded }
    empty.apply(.patches([.update(file("n.txt"))]), at: empty.location)

    await settle { empty.state.names == ["n.txt"] }
    await drainMainQueue()
    #expect(empty.selection.isEmpty)
}

/// A folder that can't be listed gives up the wait.
@MainActor @Test(arguments: [EPERM, EACCES])
func rightIntoALoadingFolderThatFailsGivesUpTheWait(code: Int32) async throws {
    let lister = GatedLister([
        "/": .batches([[folder("r")]]), "/r": .batches([[folder("no")]]),
        "/r/no": .failure(ListingError(path: "/r/no", code: code)),
    ])
    lister.release("/")
    lister.release("/r")
    let pane = Pane(
        location: Location(path: "/r"), service: ListingService(lister: lister),
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true)
    await settle { pane.state.isLoaded }
    pane.setViewMode(.column)
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    select("no", in: trail(pane).columns[1])
    #expect(await lister.waitForCall("/r/no"))
    try press(KeyChord(.right), on: pane)
    let column = trail(pane).focused
    #expect(column.selectsFirstRowAt != nil)

    lister.release("/r/no")

    await settle { column.pane.state.error != nil }
    #expect(column.selectsFirstRowAt == nil)
}

/// Cached rows are a whole listing in the column's sort, so → selects their first row.
@MainActor @Test func rightIntoAColumnWhoseCachedRowsLandSelectsTheirFirstRow() async throws {
    let share = VolumeIdentity(
        device: "//me@nas.invalid/n", mountPoint: "/Volumes/n", kind: .network)
    let cache = ListingCache(store: nil)
    for (path, entries) in [
        "/Volumes/n": [folder("docs")], "/Volumes/n/docs": [file("y.txt"), file("x.txt")],
    ] {
        await cache.insert(
            ListingCache.Folder(entries: entries, listedAt: testDate), at: path, on: share)
    }
    let lister = GatedLister(["/Volumes/n": .blockForever, "/Volumes/n/docs": .blockForever])
    lister.releaseAll()
    let service = ListingService(
        lister: lister, clock: ManualClock(), volumeOf: { _ in share }, cache: cache)
    let pane = Pane(
        location: Location(path: "/Volumes/n"), service: service,
        systemActions: StubSystemActions(),
        settings: untouchedSettings(), isFocused: true)
    await settle { pane.state.isCachedRefreshing }
    pane.setViewMode(.column)
    await settle { trail(pane).focused.pane.state.isCachedRefreshing }
    select("docs", in: trail(pane).columns[0])
    let docs = trail(pane).columns[1].pane
    #expect(docs.state.isLoading)

    try press(KeyChord(.right), on: pane)

    await settle { docs.state.isCachedRefreshing }
    await settle { docs.selection.cursor == ExactName("x.txt") }
}

// MARK: - Thumbnails

/// A focused pane at `/t` in column mode, whose service makes thumbnails with `maker` on one
/// local volume, reading previews' info with `reader` and holding them on `clock`. `/t` holds
/// the photos `a.jpg` and `b.jpg`, the text file `c.txt` and `d.jpg`, a photo that isn't
/// downloaded.
@MainActor
private func photoPane(
    maker: GatedThumbnailMaker, reader: GatedItemInfoReader, clock: ManualClock,
    thumbnails: ThumbnailService? = nil
) async -> PaneFixture {
    let notDownloaded = DirectoryEntry(
        name: "d.jpg", type: .regular, size: 9, modified: testDate, isHidden: false,
        isDataless: true)
    let fixture = PaneFixture(
        at: "/t",
        folders: [
            "/": [folder("t")],
            "/t": [file("a.jpg"), file("b.jpg"), file("c.txt"), notDownloaded],
        ],
        thumbnails: thumbnails ?? ThumbnailService(maker: maker))
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.previewHoldClock = clock
    fixture.pane.itemInfoReader = reader
    fixture.pane.setViewMode(.column)
    await settle { trail(fixture.pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    return fixture
}

/// The preview shows a file's type icon (no thumbnail) until its thumbnail is made, off the main
/// thread. A new file stays held, like its info, until its thumbnail lands, so its icon doesn't
/// show for a frame before the thumbnail replaces it.
@MainActor @Test func aPreviewShowsItsThumbnailOnceMadeAndIsHeldUntilThen() async throws {
    let maker = GatedThumbnailMaker()
    let reader = GatedItemInfoReader(["/t/a.jpg": info(1), "/t/b.jpg": info(2)])
    reader.releaseAll()
    let fixture = await photoPane(maker: maker, reader: reader, clock: ManualClock())
    let pane = fixture.pane
    let column = trail(pane).columns[1]
    let a = testThumbnail(pixels: 256)
    let b = testThumbnail(pixels: 256)

    select("a.jpg", in: column)

    #expect(trail(pane).preview?.thumbnail == nil)
    #expect(await maker.waitForCalls(1))
    #expect(
        maker.calls == [
            .init(
                path: "/t/a.jpg", side: 128, scale: 2, onMainThread: false,
                onBlockingCallThread: true)
        ])
    await settle { trail(pane).preview?.info == .read(info(1)) }
    #expect(trail(pane).shownPreview == nil)
    maker.answer("/t/a.jpg", with: a)
    await settle { trail(pane).shownPreview?.thumbnail === a }

    select("b.jpg", in: column)
    await settle { trail(pane).preview?.info == .read(info(2)) }

    #expect(trail(pane).preview?.thumbnail == nil)
    #expect(trail(pane).shownPreview?.location == Location(path: "/t/a.jpg"))
    maker.answer("/t/b.jpg", with: b)
    await settle { trail(pane).shownPreview?.thumbnail === b }
    #expect(trail(pane).shownPreview?.location == Location(path: "/t/b.jpg"))
}

/// A file whose row's thumbnail is kept shows that one, scaled, while the preview's larger one
/// is made, so its type icon never shows; the larger one replaces it once made.
@MainActor @Test func aRowsKeptThumbnailShowsWhileThePreviewsIsMade() async throws {
    let maker = GatedThumbnailMaker()
    let thumbnails = ThumbnailService(maker: maker)
    let small = testThumbnail(pixels: 32)
    maker.answer("/t/a.jpg", with: small)
    let disk = VolumeIdentity(device: "/dev/disk3s1", mountPoint: "/", kind: .local)
    let row = try await thumbnails.thumbnail(
        at: "/t/a.jpg", entry: file("a.jpg"), side: 16, on: disk)
    #expect(row === small)
    maker.hold("/t/a.jpg")
    let reader = GatedItemInfoReader(["/t/a.jpg": info(1)])
    reader.releaseAll()
    let fixture = await photoPane(
        maker: maker, reader: reader, clock: ManualClock(), thumbnails: thumbnails)
    let pane = fixture.pane

    select("a.jpg", in: trail(pane).columns[1])

    #expect(trail(pane).preview?.thumbnail === small)
    await settle { trail(pane).shownPreview?.info == .read(info(1)) }
    #expect(trail(pane).shownPreview?.thumbnail === small)
    #expect(await maker.waitForCalls(2))
    let large = testThumbnail(pixels: 256)
    maker.answer("/t/a.jpg", with: large)
    await settle { trail(pane).shownPreview?.thumbnail === large }
}

/// A thumbnail that takes longer than the hold shows in place of the icon once it lands.
@MainActor @Test func aThumbnailMadeAfterTheHoldReplacesTheIcon() async throws {
    let maker = GatedThumbnailMaker()
    let reader = GatedItemInfoReader(["/t/a.jpg": info(1)])
    reader.releaseAll()
    let clock = ManualClock()
    let fixture = await photoPane(maker: maker, reader: reader, clock: clock)
    let pane = fixture.pane
    let image = testThumbnail(pixels: 256)

    select("a.jpg", in: trail(pane).columns[1])
    #expect(await maker.waitForCalls(1))
    clock.advance(by: ColumnTrail.previewHold)

    await settle { trail(pane).shownPreview?.location == Location(path: "/t/a.jpg") }
    #expect(trail(pane).shownPreview?.thumbnail == nil)
    maker.answer("/t/a.jpg", with: image)
    await settle { trail(pane).shownPreview?.thumbnail === image }
}

/// A file previewed again shows the thumbnail kept of it at once, without asking again.
@MainActor @Test func aKeptThumbnailShowsAtOnce() async throws {
    let maker = GatedThumbnailMaker()
    let a = testThumbnail(pixels: 256)
    maker.answer("/t/a.jpg", with: a)
    maker.answer("/t/b.jpg", with: nil)
    let reader = GatedItemInfoReader(["/t/a.jpg": info(1), "/t/b.jpg": info(2)])
    reader.releaseAll()
    let fixture = await photoPane(maker: maker, reader: reader, clock: ManualClock())
    let pane = fixture.pane
    let column = trail(pane).columns[1]
    select("a.jpg", in: column)
    await settle { trail(pane).shownPreview?.thumbnail === a }
    select("b.jpg", in: column)
    await settle { trail(pane).shownPreview?.location == Location(path: "/t/b.jpg") }

    select("a.jpg", in: column)

    #expect(trail(pane).preview?.thumbnail === a)
    #expect(maker.paths == ["/t/a.jpg", "/t/b.jpg"])
}

/// Text keeps its type icon, and a file that isn't downloaded makes none, since making one would
/// download it: neither is asked for.
@MainActor @Test func aTextOrNotDownloadedFileAsksForNoThumbnail() async throws {
    let maker = GatedThumbnailMaker()
    let reader = GatedItemInfoReader(["/t/c.txt": info(3)])
    reader.releaseAll()
    let fixture = await photoPane(maker: maker, reader: reader, clock: ManualClock())
    let pane = fixture.pane
    let column = trail(pane).columns[1]

    select("c.txt", in: column)
    await settle { trail(pane).shownPreview?.info == .read(info(3)) }
    select("d.jpg", in: column)
    #expect(trail(pane).shownPreview?.location == Location(path: "/t/d.jpg"))
    for _ in 0..<3 { await drainMainQueue() }

    #expect(maker.calls.isEmpty)
    #expect(trail(pane).preview?.thumbnail == nil)
}

/// A focused pane at `/t` in column mode, on a share as one reached through a link under `/`
/// is, whose service makes thumbnails with `maker`, reading previews' info with `reader` and
/// holding them on `clock`. `/t` holds the photos `a.jpg`, `b.jpg` and `c.jpg`.
@MainActor
private func sharePhotoPane(
    maker: GatedThumbnailMaker, reader: GatedItemInfoReader, clock: ManualClock = ManualClock()
) async -> Pane {
    let share = VolumeIdentity(device: "//nas/share", mountPoint: "/Volumes/nas", kind: .network)
    let lister = GatedLister([
        "/": .batches([[folder("t")]]),
        "/t": .batches([[file("a.jpg"), file("b.jpg"), file("c.jpg")]]),
    ])
    lister.releaseAll()
    let pane = Pane(
        location: Location(path: "/t"),
        service: ListingService(
            lister: lister, volumeOf: { _ in share },
            // A clock never advanced, so no request is given up.
            thumbnails: ThumbnailService(maker: maker, clock: ManualClock())),
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true)
    pane.previewHoldClock = clock
    pane.itemInfoReader = reader
    await settle { pane.state.isLoaded }
    pane.setViewMode(.column)
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    #expect(trail(pane).focused.pane.folderVolume == share)
    return pane
}

/// The preview of a file on a share shows its thumbnail, as Finder's does, though the share's
/// rows ask for none. The folder's volume is the one its load read, so `/t` is on the share.
@MainActor @Test func aFileOnAShareShowsItsThumbnailInThePreview() async throws {
    let maker = GatedThumbnailMaker()
    let image = testThumbnail(pixels: 256)
    maker.answer("/t/a.jpg", with: image)
    let reader = GatedItemInfoReader(["/t/a.jpg": info(1)])
    reader.releaseAll()
    let pane = await sharePhotoPane(maker: maker, reader: reader)

    select("a.jpg", in: trail(pane).columns[1])

    await settle { trail(pane).shownPreview?.thumbnail === image }
    #expect(maker.paths == ["/t/a.jpg"])
    #expect(maker.calls.allSatisfy { $0.onBlockingCallThread })
}

/// Moving the selection on through a folder on a share stops the earlier file's thumbnail, so
/// only the latest file's runs and no backlog of requests reads over the network.
@MainActor @Test func movingOnThroughAShareStopsTheEarlierThumbnail() async throws {
    let maker = GatedThumbnailMaker()
    let reader = GatedItemInfoReader([
        "/t/a.jpg": info(1), "/t/b.jpg": info(2), "/t/c.jpg": info(3),
    ])
    reader.releaseAll()
    let pane = await sharePhotoPane(maker: maker, reader: reader)
    let column = trail(pane).columns[1]
    let thumbnails = try #require(pane.service.thumbnails)

    select("a.jpg", in: column)
    #expect(await maker.waitForCalls(1))
    select("b.jpg", in: column)
    #expect(await maker.waitForCalls(2))
    select("c.jpg", in: column)
    #expect(await maker.waitForCalls(3))

    #expect(maker.paths == ["/t/a.jpg", "/t/b.jpg", "/t/c.jpg"])
    await settle { maker.stopped == ["/t/a.jpg", "/t/b.jpg"] }
    #expect(thumbnails.calls.waitingCount(on: trail(pane).focused.pane.folderVolume) == 0)
    let image = testThumbnail(pixels: 256)
    maker.answer("/t/a.jpg", with: testThumbnail(pixels: 256))
    maker.answer("/t/c.jpg", with: image)
    await settle { trail(pane).shownPreview?.thumbnail === image }
    #expect(trail(pane).shownPreview?.location == Location(path: "/t/c.jpg"))
    await settle { thumbnails.calls.isIdle }
}

/// A share that never answers the thumbnail leaves the preview showing the file's icon, with
/// its info, once the hold passes.
@MainActor @Test func aThumbnailAShareNeverAnswersLeavesTheIcon() async throws {
    let maker = GatedThumbnailMaker()
    let reader = GatedItemInfoReader(["/t/a.jpg": info(1)])
    reader.releaseAll()
    let clock = ManualClock()
    let pane = await sharePhotoPane(maker: maker, reader: reader, clock: clock)

    select("a.jpg", in: trail(pane).columns[1])
    #expect(await maker.waitForCalls(1))
    clock.advance(by: ColumnTrail.previewHold)

    await settle { trail(pane).shownPreview?.info == .read(info(1)) }
    #expect(trail(pane).shownPreview?.location == Location(path: "/t/a.jpg"))
    #expect(trail(pane).shownPreview?.thumbnail == nil)
    trail(pane).close()
    await settle { maker.stopped == ["/t/a.jpg"] }
}

/// A file in rows its volume hasn't answered with, as a slow listing keeps them, gets no
/// thumbnail: making one could wait on a disk that stopped answering.
@MainActor @Test func aFileInRowsTheVolumeHasntAnsweredWithAsksForNoThumbnail() async throws {
    let lister = HoldableLister(["/": [folder("t")], "/t": [file("a.jpg")]])
    let clock = ManualClock()
    let maker = GatedThumbnailMaker()
    // Answered, so a request that reached the maker would land in the preview.
    maker.answer("/t/a.jpg", with: testThumbnail(pixels: 256))
    let pane = Pane(
        location: Location(path: "/t"),
        service: ListingService(
            lister: lister, clock: clock, thumbnails: ThumbnailService(maker: maker)),
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true)
    pane.itemInfoReader = GatedItemInfoReader(["/t/a.jpg": info(1)])
    await settle { pane.state.isLoaded }
    pane.setViewMode(.column)
    let column = trail(pane).columns[1].pane
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }
    lister.hold()
    column.reload()
    clock.advance(by: LoadTimeouts.slow)
    await settle { column.state.isSlow }

    select("a.jpg", in: trail(pane).columns[1])

    #expect(trail(pane).preview?.location == Location(path: "/t/a.jpg"))
    for _ in 0..<3 { await drainMainQueue() }
    #expect(maker.calls.isEmpty)
    #expect(trail(pane).shownPreview?.thumbnail == nil)
    lister.release()
}
