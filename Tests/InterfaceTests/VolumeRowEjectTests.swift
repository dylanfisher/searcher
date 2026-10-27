import AppKit
import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

// A row of a list or a column whose item is a volume the sidebar can eject shows Finder's eject
// button at the end of its name, which ejects it as the sidebar's does, is off while that eject
// runs, and follows the sidebar's volumes as they come and go
// (docs/decisions/0118-row-eject-buttons.md). Each test goes through a real window, its panes,
// views and sidebar volumes; the listing, the volumes read and the ejects are stubs.

private let startup = SidebarVolume(
    mountPoint: "/", name: "Macintosh HD", kind: .local, isRootFileSystem: true, isInternal: true)
private let usb = SidebarVolume(
    mountPoint: "/Volumes/USB", name: "USB", kind: .local, isInternal: false)
private let share = SidebarVolume(mountPoint: "/Volumes/main", name: "main", kind: .network)
/// A second internal disk, which the sidebar doesn't list and which can't be ejected.
private let backup = SidebarVolume(
    mountPoint: "/Volumes/Backup", name: "Backup", kind: .local, isInternal: true)

private func link(_ name: String) -> DirectoryEntry {
    DirectoryEntry(
        name: name, type: .symbolicLink, size: nil, modified: testDate, isHidden: false,
        isDataless: false)
}

/// /Volumes as the system has it: the startup disk's link, an internal disk, a USB disk and a
/// share.
private let folders: [String: [DirectoryEntry]] = [
    "/": [folder("Volumes")],
    "/Volumes": [folder("Backup"), link("Macintosh HD"), folder("USB"), folder("main")],
    "/Volumes/Backup": [],
    "/Volumes/USB": [file("a.txt")],
    "/Volumes/main": [file("n.txt")],
]

/// A focused pane at /Volumes in `viewMode`, in a window whose sidebar reads its volumes from
/// `mounts`.
@MainActor
private struct VolumesWindow {
    let mounts: StubSidebarVolumes
    let volumes: SidebarVolumes
    let controller: BrowserWindowController
    let paneController: PaneViewController
    let pane: Pane

    init(viewMode: ViewMode, mounted: [SidebarVolume] = [startup, backup, usb, share]) async throws
    {
        mounts = StubSidebarVolumes(mounted)
        let volumes = mounts.list()
        self.volumes = volumes
        await settle { volumes.readsLanded > 0 }
        let settings = untouchedSettings()
        pane = Pane(
            location: Location(path: "/Volumes"),
            service: ListingService(lister: StubLister(folders)),
            systemActions: StubSystemActions(), settings: settings, isFocused: true,
            viewMode: viewMode)
        var made: PaneViewController?
        controller = BrowserWindowController(
            workspace: Workspace(tab: Tab(pane: pane)), workspaces: WorkspaceList(),
            favorites: Favorites(settings: settings), volumes: volumes, settings: settings,
            takePaneController: { _, pane in
                let controller = PaneViewController(
                    pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
                    tableView: ListingTableView(), monitorsFolders: false)
                made = controller
                return controller
            })
        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        paneController = try #require(made)
        await settle { self.volumesPane?.state.isLoaded == true }
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// The pane listing /Volumes: the pane itself, or its column.
    var volumesPane: Pane? {
        guard let trail = pane.columnTrail else { return pane }
        return trail.columns.first { $0.pane.location == Location(path: "/Volumes") }?.pane
    }

    /// The list showing /Volumes: the list's, or its column.
    var list: ListingViewController {
        get throws {
            guard pane.columnTrail != nil else { return paneController.listingViewController }
            let shown = paneController.columnViewController.columnControllers
            return try #require(shown.first { $0.pane.location == Location(path: "/Volumes") })
        }
    }

    func row(of name: String) throws -> Int {
        let listing = try #require(volumesPane?.state.listing)
        return try #require((0..<listing.count).first { listing[$0].name == name })
    }

    /// The eject button `name`'s row shows, nil when it shows none.
    func ejectButton(_ name: String) throws -> HoverButton? {
        try list.shownEjectButton(atRow: try row(of: name))
    }

    /// Mounts `volumes` in place of those mounted, as the system reports a mount, and waits for
    /// the sidebar's list to hold them.
    func mount(_ volumes: [SidebarVolume]) async {
        mounts.set(volumes)
        VolumeEvents.didMount(at: "/row-eject-test-\(UUID().uuidString)")
        let shown = volumes.filter(\.isShown)
        await settle { self.volumes.volumes == shown }
    }
}

extension ListingViewController {
    /// The Name cell the table shows for `row`.
    func shownNameCell(atRow row: Int) throws -> NSTableCellView {
        let column = tableView.column(withIdentifier: SortColumn.name.identifier)
        try #require(column >= 0)
        return try #require(
            tableView.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)
    }

    /// The eject button the Name cell of `row` shows, nil when it shows none.
    func shownEjectButton(atRow row: Int) throws -> HoverButton? {
        try shownNameCell(atRow: row).subviews.lazy.compactMap { $0 as? HoverButton }
            .first { !$0.isHidden }
    }
}

@MainActor @Test(arguments: [ViewMode.list, .column])
func aVolumesRowShowsAnEjectButtonOnlyWhenTheSidebarCanEjectIt(_ viewMode: ViewMode)
    async throws
{
    let window = try await VolumesWindow(viewMode: viewMode)

    #expect(try window.ejectButton("USB") != nil)
    #expect(try window.ejectButton("main") != nil)
    #expect(try window.ejectButton("Backup") == nil)
    #expect(try window.ejectButton("Macintosh HD") == nil)

    // Finder's glyph, at the end of the name, the name ending before it; in a column, left of
    // the chevron.
    let list = try window.list
    let cell = try list.shownNameCell(atRow: try window.row(of: "USB"))
    let eject = try #require(try window.ejectButton("USB"))
    #expect(String(describing: eject.image).contains("eject.fill"))
    #expect(eject.isEnabled)
    // VoiceOver names the volume, in the words of the menu's Eject.
    #expect(eject.accessibilityLabel() == "Eject “USB”")
    #expect(try window.ejectButton("main")?.accessibilityLabel() == "Eject “main”")
    let name = try #require(cell.textField)
    #expect(name.frame.maxX <= eject.frame.minX)
    if let chevron = ListingCellLayout.chevron(in: cell) {
        #expect(viewMode == .column)
        #expect(!chevron.isHidden)
        #expect(eject.frame.maxX <= chevron.frame.minX)
    } else {
        #expect(eject.frame.maxX <= cell.bounds.maxX)
        #expect(eject.frame.maxX > cell.bounds.maxX - HoverButton.side - 4)
    }
    let nameFrame = list.nameFrame(atRow: try window.row(of: "USB"))
    #expect(nameFrame.maxX <= list.tableView.convert(eject.frame, from: cell).minX)
}

@MainActor @Test(arguments: [ViewMode.list, .column])
func aVolumesEjectButtonEjectsItIsOffWhileItRunsAndGoesWithIt(_ viewMode: ViewMode)
    async throws
{
    let window = try await VolumesWindow(viewMode: viewMode)
    let list = try window.list
    let mainRow = try window.row(of: "main")
    list.pane.select(Selection([ExactName("main")], cursor: ExactName("main")))
    let selected = list.tableView.selectedRowIndexes
    #expect(selected == [mainRow])
    window.mounts.holdEjects()

    try #require(try window.ejectButton("USB")).performClick(nil)

    await settle { window.mounts.ejects.count == 1 }
    #expect(window.mounts.ejects.map(\.mountPoint) == ["/Volumes/USB"])
    #expect(window.mounts.ejects.map(\.onBlockingThread) == [true])
    await settle { (try? window.ejectButton("USB")?.isEnabled) == false }
    #expect(try window.ejectButton("main")?.isEnabled == true)
    // A second click, or the menu's Eject, does nothing while it runs.
    try #require(try window.ejectButton("USB")).performClick(nil)
    #expect(window.mounts.ejects.count == 1)
    // The click left the selection and the folder shown alone.
    #expect(list.pane.selection.cursor == ExactName("main"))
    #expect(list.tableView.selectedRowIndexes == selected)
    if viewMode == .list { #expect(window.pane.location == Location(path: "/Volumes")) }

    window.mounts.releaseEjects()
    await window.mount([startup, backup, share])

    #expect(try window.ejectButton("USB") == nil)
    #expect(try window.ejectButton("main")?.isEnabled == true)
}

@MainActor @Test(arguments: [ViewMode.list, .column])
func aVolumesEjectButtonComesAndGoesWithTheSidebarsVolumes(_ viewMode: ViewMode) async throws {
    let window = try await VolumesWindow(viewMode: viewMode, mounted: [startup, backup])
    #expect(try window.ejectButton("USB") == nil)

    await window.mount([startup, backup, usb])

    #expect(try window.ejectButton("USB") != nil)
    #expect(try window.ejectButton("main") == nil)
}

/// A cell that showed the button for a volume's row and is filled again for another row, here
/// by reversing the sort, shows none, and the volume's row, now in another cell, shows it.
@MainActor @Test(arguments: [ViewMode.list, .column])
func aCellFilledAgainForARowThatIsntAVolumeDropsTheEjectButton(_ viewMode: ViewMode)
    async throws
{
    let window = try await VolumesWindow(viewMode: viewMode)
    let list = try window.list
    let usbRow = try window.row(of: "USB")
    let cell = try list.shownNameCell(atRow: usbRow)
    let eject = try #require(try window.ejectButton("USB"))

    list.pane.setSort(.name, ascending: false)
    await settle { (try? window.row(of: "USB")) != usbRow }

    let filled = try list.shownNameCell(atRow: usbRow)
    #expect(filled === cell)
    // Reversed, the row holds "Backup" or the startup disk's link, neither a volume to eject.
    let shown = try #require(filled.textField?.stringValue)
    #expect(["Backup", "Macintosh HD"].contains(shown))
    #expect(try list.shownEjectButton(atRow: usbRow) == nil)
    #expect(eject.isHidden)
    #expect(try window.ejectButton("USB")?.accessibilityLabel() == "Eject “USB”")
}

@MainActor @Test func aVolumesRowOffersEjectInItsMenuAsItsButtonDoes() async throws {
    let window = try await VolumesWindow(viewMode: .list)
    let list = try window.list
    list.tableView.registry = try AppCommands.registry()

    let menu = list.contextMenu(forRow: try window.row(of: "USB"))
    let eject = try #require(menu.items.last)
    #expect(eject.title == "Eject “USB”")
    #expect(
        !list.contextMenu(forRow: try window.row(of: "Backup")).items.contains {
            $0.title.hasPrefix("Eject")
        })

    NSApp.sendAction(try #require(eject.action), to: eject.target, from: eject)
    await settle { !window.mounts.ejects.isEmpty }
    #expect(window.mounts.ejects.map(\.mountPoint) == ["/Volumes/USB"])
}

@MainActor @Test func aVolumeThatWontEjectSaysWhyFromItsRowsButton() async throws {
    let window = try await VolumesWindow(viewMode: .list)
    window.mounts.fail(with: "It’s in use.")
    var alerts: [NSAlert] = []
    let list = try window.list
    list.showAlert = { alerts.append($0) }

    try #require(try window.ejectButton("USB")).performClick(nil)

    await settle { !alerts.isEmpty }
    #expect(alerts.first?.messageText == "The disk “USB” wasn’t ejected.")
    #expect(alerts.first?.informativeText == "It’s in use.")
    await settle { (try? window.ejectButton("USB")?.isEnabled) == true }
}

/// A real press on the button reaches the button, not the table: the row isn't selected and the
/// pane keeps its selection.
@MainActor @Test(arguments: [ViewMode.list, .column])
func aPressOnAVolumesEjectButtonEjectsItWithoutSelectingTheRow(_ viewMode: ViewMode)
    async throws
{
    let window = try await VolumesWindow(viewMode: viewMode)
    let nsWindow = try #require(window.controller.window)
    SecondDisplay.orderFront(nsWindow)
    defer { nsWindow.orderOut(nil) }
    nsWindow.contentView?.layoutSubtreeIfNeeded()
    let list = try window.list
    list.pane.select(Selection([ExactName("main")], cursor: ExactName("main")))
    let selected = list.tableView.selectedRowIndexes
    let eject = try #require(try window.ejectButton("USB"))
    let point = eject.convert(NSPoint(x: eject.bounds.midX, y: eject.bounds.midY), to: nil)
    let content = try #require(nsWindow.contentView)
    #expect(content.hitTest(try #require(content.superview).convert(point, from: nil)) === eject)
    func event(_ type: NSEvent.EventType) throws -> NSEvent {
        try mouseEvent(type, at: point, in: nsWindow)
    }
    nonisolated(unsafe) let down = try event(.leftMouseDown)
    nonisolated(unsafe) var held: NSColor?

    try performRealPress(
        releasedBy: try event(.leftMouseUp), pressesButton: true,
        whileDown: { held = eject.glyphTint }, { eject.mouseDown(with: down) })

    #expect(held == HoverButton.glyphTint(.pressed, onEmphasizedSelection: false))
    await settle { window.mounts.ejects.count == 1 }
    #expect(window.mounts.ejects.map(\.mountPoint) == ["/Volumes/USB"])
    #expect(list.pane.selection.cursor == ExactName("main"))
    #expect(list.tableView.selectedRowIndexes == selected)
}

/// On an emphasized selection the glyph takes the selected row's text color, as the chevron
/// and the name do.
@MainActor @Test(arguments: [ViewMode.list, .column])
func aVolumesEjectButtonOnAnEmphasizedRowTakesTheSelectedTextColor(_ viewMode: ViewMode)
    async throws
{
    let window = try await VolumesWindow(viewMode: viewMode)
    let cell = try window.list.shownNameCell(atRow: try window.row(of: "USB"))
    let eject = try #require(try window.ejectButton("USB"))
    #expect(eject.glyphTint == .tertiaryLabelColor)

    cell.backgroundStyle = .emphasized

    #expect(eject.glyphTint == HoverButton.glyphTint(.rest, onEmphasizedSelection: true))
    cell.backgroundStyle = .normal
    #expect(eject.glyphTint == .tertiaryLabelColor)
}
