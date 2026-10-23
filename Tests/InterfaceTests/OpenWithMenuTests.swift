import AppKit
import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing
import UniformTypeIdentifiers

@testable import Browser
@testable import Interface

private let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
private let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
private let quickTime = URL(fileURLWithPath: "/System/Applications/QuickTime Player.app")

/// A loaded pane at `/folder` holding `a.txt`, `b.txt` and `docs`, the cache for its Open With
/// menu, and the menu. No panel shows: Other… asks `chosen` for its app.
@MainActor
private struct Fixture {
    let pane: Pane
    let actions: StubSystemActions
    let cache: OpenWith
    let openWithMenu: OpenWithMenu
    /// What each Other… was answered with.
    let chooser = Chooser()

    init(hasTarget: Bool = true, apps: [OpenWith.App] = []) async {
        actions = StubSystemActions(
            applications: [.plainText: [textEdit, quickTime, preview] + apps.map(\.url)],
            defaultApplications: [.plainText: textEdit], apps: apps)
        pane = Pane(
            location: Location(path: "/folder"),
            service: ListingService(
                lister: StubLister(["/folder": [file("a.txt"), file("b.txt"), folder("docs")]])),
            systemActions: actions, settings: untouchedSettings())
        cache = OpenWith(systemActions: actions, didBuild: { _, _ in })
        let pane = pane
        let cache = cache
        let chooser = chooser
        openWithMenu = OpenWithMenu(
            target: { hasTarget ? OpenWithMenu.Target(openWith: cache, pane: pane) : nil },
            chooseApp: { chosen in
                chooser.asked += 1
                chooser.answer.map(chosen)
            })
        await settle { pane.state.isLoaded }
    }

    var item: NSMenuItem { openWithMenu.item }

    var submenu: NSMenu {
        get throws { try #require(item.submenu) }
    }

    /// Fills the submenu as AppKit does before it shows it.
    func open() throws -> NSMenu {
        let menu = try submenu
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu
    }

    func select(_ names: String...) {
        pane.select(
            Selection(Set(names.map(ExactName.init)), cursor: names.last.map(ExactName.init)))
    }
}

@MainActor
private final class Chooser {
    var asked = 0
    var answer: URL?
}

/// The titles of `menu`'s items, a separator as "-".
@MainActor
private func titles(_ menu: NSMenu) -> [String] {
    menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
}

/// Turns `menu`'s items on and off as AppKit does before it shows the menu. NSMenu validates
/// nothing until the app object exists.
@MainActor
private func validate(_ menu: NSMenu) {
    _ = NSApplication.shared
    menu.update()
}

/// The parts of `item`'s title drawn in the secondary label color, as Finder draws "(default)"
/// and an app's version.
@MainActor
private func secondaryText(_ item: NSMenuItem) -> [String] {
    guard let title = item.attributedTitle else { return [] }
    var parts: [String] = []
    title.enumerateAttribute(
        .foregroundColor, in: NSRange(location: 0, length: title.length)
    ) { value, range, _ in
        if value as? NSColor == .secondaryLabelColor {
            parts.append((title.string as NSString).substring(with: range))
        }
    }
    return parts
}

/// Sends `item`'s action to its target, as choosing it in the menu does.
@MainActor
private func choose(_ item: NSMenuItem) throws {
    let target = try #require(item.target as? NSObject)
    let action = try #require(item.action as Selector?)
    _ = target.perform(action, with: item)
}

@MainActor @Test func theMenuListsTheDefaultAppThenTheRestByNameThenOther() async throws {
    let fixture = await Fixture()
    fixture.select("a.txt", "b.txt")
    _ = await fixture.cache.choices(for: [.plainText])

    let menu = try fixture.open()

    #expect(
        titles(menu) == [
            "TextEdit (default)", "-", "Preview", "QuickTime Player", "-",
            OpenWithMenu.appStoreTitle, OpenWithMenu.otherTitle,
        ])
    validate(menu)
    let enabled = menu.items.filter { !$0.isSeparatorItem }.map(\.isEnabled)
    #expect(enabled == [true, true, true, true, true])
}

@MainActor @Test func aMenuOpenedBeforeTheListIsBuiltShowsLoadingThenTheApps() async throws {
    let fixture = await Fixture()
    let held = DispatchQueue(label: "OpenWithMenuTests.held")
    held.suspend()
    fixture.cache.buildQueue = held
    fixture.select("a.txt")

    let menu = try fixture.open()

    #expect(
        titles(menu) == [
            OpenWithMenu.loadingTitle, "-", OpenWithMenu.appStoreTitle, OpenWithMenu.otherTitle,
        ])
    validate(menu)
    #expect(menu.items.first?.isEnabled == false)

    held.resume()
    await settle { menu.items.count == 7 }
    #expect(
        titles(menu) == [
            "TextEdit (default)", "-", "Preview", "QuickTime Player", "-",
            OpenWithMenu.appStoreTitle, OpenWithMenu.otherTitle,
        ])
}

@MainActor @Test func choosingAnAppOpensTheSelectionWithIt() async throws {
    let fixture = await Fixture()
    fixture.select("a.txt", "b.txt")
    _ = await fixture.cache.choices(for: [.plainText])
    let menu = try fixture.open()

    try choose(try #require(menu.items.first { $0.title == "Preview" }))

    #expect(fixture.actions.openedWithApp.map(\.application) == [preview])
    #expect(
        fixture.actions.openedWithApp.first?.urls == [
            URL(fileURLWithPath: "/folder/a.txt", isDirectory: false),
            URL(fileURLWithPath: "/folder/b.txt", isDirectory: false),
        ])
}

@MainActor @Test func otherAsksForAnAppAndOpensTheSelectionWithTheOneChosen() async throws {
    let fixture = await Fixture()
    fixture.select("a.txt")
    _ = await fixture.cache.choices(for: [.plainText])
    let menu = try fixture.open()
    let other = try #require(menu.items.first { $0.title == OpenWithMenu.otherTitle })

    try choose(other)
    #expect(fixture.chooser.asked == 1)
    #expect(fixture.actions.openedWithApp.isEmpty)

    fixture.chooser.answer = quickTime
    try choose(other)
    #expect(fixture.actions.openedWithApp.map(\.application) == [quickTime])
    #expect(
        fixture.actions.openedWithApp.first?.urls == [
            URL(fileURLWithPath: "/folder/a.txt", isDirectory: false)
        ])
}

@MainActor @Test func openWithIsOffWithNothingSelectedOrNoCache() async throws {
    let fixture = await Fixture()
    let menu = NSMenu()
    menu.addItem(fixture.item)

    validate(menu)
    #expect(!fixture.item.isEnabled)
    fixture.select("a.txt")
    validate(menu)
    #expect(fixture.item.isEnabled)

    let noCache = await Fixture(hasTarget: false)
    noCache.select("a.txt")
    let other = NSMenu()
    other.addItem(noCache.item)
    validate(other)
    #expect(!noCache.item.isEnabled)
}

@MainActor @Test func theRowMenuAndTheFileMenuHaveOpenWith() throws {
    let registry = try AppCommands.registry()
    let rowMenu = try ContextMenuBuilder.build(
        ContextMenuBuilder.rowItems, registry: registry, target: ListingTableView(),
        selection: [])
    let folderMenu = try ContextMenuBuilder.build(
        ContextMenuBuilder.folderItems, registry: registry, target: ListingTableView(),
        selection: [])
    NSMenuItem.usesUserKeyEquivalents = false
    let bar = try MainMenuBuilder.build(appName: "Searcher", registry: registry)
    let fileMenu = try #require(bar.items.first { $0.title == "File" }?.submenu)

    for menu in [rowMenu, fileMenu] {
        let item = try #require(menu.items.first { $0.title == OpenWithMenu.title })
        #expect(item.submenu?.delegate is OpenWithMenu)
    }
    #expect(!folderMenu.items.contains { $0.title == OpenWithMenu.title })
}

@MainActor @Test func aWindowsTablesOpenWithTheWindowsCacheOnTheirPane() async throws {
    let actions = StubSystemActions()
    let cache = OpenWith(systemActions: actions, didBuild: { _, _ in })
    let pane = Pane(
        location: Location(path: "/folder"),
        service: ListingService(lister: StubLister(["/folder": [file("a.txt")], "/": []])) {
            "Test Disk"
        },
        systemActions: actions, settings: untouchedSettings())
    let workspaces = WorkspaceList()
    let workspace = Workspace(tab: Tab(pane: pane))
    workspaces.add(workspace)
    let controller = BrowserWindowController(
        workspace: workspace, workspaces: workspaces, settings: pane.settings, openWith: cache)
    let window = try #require(controller.window)
    window.contentView?.layoutSubtreeIfNeeded()
    await settle { pane.state.isLoaded }
    let table = try #require(window.firstResponder as? ListingTableView)

    let target = try #require(table.openWith())

    #expect(target.openWith === cache)
    #expect(target.pane === pane)
}

@MainActor @Test func eachAppShowsItsIconAndTheDefaultIsMarkedInSecondaryText() async throws {
    let fixture = await Fixture()
    fixture.select("a.txt")
    _ = await fixture.cache.choices(for: [.plainText])

    let menu = try fixture.open()

    let defaultItem = try #require(menu.items.first)
    #expect(defaultItem.title == "TextEdit (default)")
    #expect(secondaryText(defaultItem) == [" (default)"])
    let apps = menu.items.filter { $0.representedObject is URL }
    #expect(apps.count == 3)
    for item in apps {
        let image = try #require(item.image, "\(item.title)")
        #expect(image.size == NSSize(width: 16, height: 16), "\(item.title)")
        #expect(
            image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width == 1,
            "\(item.title)")
    }
}

@MainActor @Test func twoAppsWithOneNameShowTheirVersionsInSecondaryText() async throws {
    let paths = ["/a/Google Chrome for Testing.app", "/b/Google Chrome for Testing.app"]
    let apps = zip(paths, ["152.0.7500.4", "153.0.8010.12"]).map { path, version in
        OpenWith.App(
            url: URL(fileURLWithPath: path, isDirectory: true),
            bundleID: "com.google.chrome.for.testing", name: "Google Chrome for Testing.app",
            version: version)
    }
    let fixture = await Fixture(apps: apps)
    fixture.select("a.txt")
    _ = await fixture.cache.choices(for: [.plainText])

    let menu = try fixture.open()

    let chrome = menu.items.filter { $0.title.hasPrefix("Google Chrome for Testing.app") }
    #expect(
        chrome.map(\.title) == [
            "Google Chrome for Testing.app (152.0.7500.4)",
            "Google Chrome for Testing.app (153.0.8010.12)",
        ])
    #expect(chrome.map(secondaryText) == [[" (152.0.7500.4)"], [" (153.0.8010.12)"]])
    let preview = try #require(menu.items.first { $0.title == "Preview" })
    #expect(secondaryText(preview).isEmpty)
}

@MainActor @Test func appStoreSearchesTheStoreForTheSelectionsType() async throws {
    let fixture = await Fixture()
    fixture.select("a.txt")
    _ = await fixture.cache.choices(for: [.plainText])
    let menu = try fixture.open()

    try choose(try #require(menu.items.first { $0.title == OpenWithMenu.appStoreTitle }))

    #expect(
        fixture.actions.openedURLs == [
            try #require(URL(string: "macappstore://?action=search&term=txt"))
        ])
}
