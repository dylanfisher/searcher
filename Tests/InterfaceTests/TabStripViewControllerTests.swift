import AppKit
import Browser
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Interface

/// A workspace of one tab at `/root`, and its tab strip, never shown.
@MainActor
private struct Fixture {
    let service = ListingService(
        lister: StubLister(["/root": [folder("docs")], "/root/docs": [], "/other": []])
    ) { "Test Disk" }
    let settings = untouchedSettings()
    let workspace: Workspace
    let strip: TabStripViewController

    init() {
        workspace = Workspace(tab: Tab(pane: Self.pane(at: "/root", service, settings)))
        strip = TabStripViewController(workspace: workspace)
    }

    /// Adds a tab at `path` after the selected one and selects it, as Cmd-T does.
    func addTab(at path: String) {
        workspace.add(Tab(pane: Self.pane(at: path, service, settings)))
        strip.update()
    }

    private static func pane(at path: String, _ service: ListingService, _ settings: Settings)
        -> Pane
    {
        Pane(
            location: Location(path: path), service: service, systemActions: StubSystemActions(),
            settings: settings)
    }
}

@MainActor @Test func theStripHidesWithOneTabAndShowsEachTabsFolder() {
    let fixture = Fixture()
    fixture.strip.update()
    #expect(fixture.strip.view.isHidden)

    fixture.addTab(at: "/other")

    #expect(!fixture.strip.view.isHidden)
    #expect(fixture.strip.tabStripView.titles == ["root", "other"])
    #expect(fixture.strip.tabStripView.selectedIndex == 1)
}

@MainActor @Test func aTabsTitleFollowsItsFocusedPanesFolder() {
    let fixture = Fixture()
    fixture.addTab(at: "/other")
    let first = fixture.workspace.tabs[0]

    first.focusedPane.navigate(to: Location(path: "/root/docs"))
    fixture.strip.update()

    #expect(fixture.strip.tabStripView.titles == ["docs", "other"])
}

@MainActor @Test func clickingATabSelectsItInTheWorkspace() {
    let fixture = Fixture()
    fixture.addTab(at: "/other")
    var selected = 0
    fixture.strip.didChangeTabs = { selected += 1 }

    fixture.strip.tabStripView.click(0)

    #expect(fixture.workspace.selectedTab === fixture.workspace.tabs[0])
    #expect(fixture.strip.tabStripView.selectedIndex == 0)
    #expect(selected == 1)
}

@MainActor @Test func theStripIsATabGroupNamedForVoiceOver() {
    let fixture = Fixture()
    fixture.addTab(at: "/other")

    let tabs = fixture.strip.tabStripView.tabs
    #expect(tabs.count == 2)
    #expect(tabs[1].accessibilityLabel() == "other")
    #expect(fixture.strip.tabStripView.accessibilityLabel() == TabStripView.accessibilityName)
}

@MainActor @Test func closingATabInTheStripClosesItInTheWorkspace() throws {
    let fixture = Fixture()
    fixture.addTab(at: "/other")
    let first = fixture.workspace.tabs[0]
    let second = fixture.workspace.tabs[1]
    var changes = 0
    fixture.strip.didChangeTabs = { changes += 1 }

    let close = fixture.strip.tabStripView.tabs[0].closeButton
    #expect(
        NSApplication.shared.sendAction(try #require(close.action), to: close.target, from: close))

    #expect(fixture.workspace.tabs.map(\.id) == [second.id])
    #expect(first.isClosed)
    #expect(fixture.strip.view.isHidden)
    #expect(changes == 1)
}
