import AppKit
import Base
import Browser
import BrowserTestSupport
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Interface

/// A pane in a view controller that is never shown. `/root/Mail` refuses to list with EPERM, as a
/// privacy-protected folder does, `/root/locked` with EACCES, as a folder whose Unix permissions
/// shut the user out does, and `/root/gone` fails with ENOENT.
@MainActor
private struct DeniedFixture {
    let pane: Pane
    let actions = StubSystemActions()
    let controller: PaneViewController
    let table = ListingTableView()

    init(at path: String) {
        let lister = GatedLister([
            "/root": .batches([[folder("Mail"), folder("gone")]]),
            "/root/Mail": .failure(ListingError(path: "/root/Mail", code: EPERM)),
            "/root/locked": .failure(ListingError(path: "/root/locked", code: EACCES)),
            "/root/gone": .failure(ListingError(path: "/root/gone", code: ENOENT)),
        ])
        lister.releaseAll()
        pane = Pane(
            location: Location(path: path), service: ListingService(lister: lister),
            systemActions: actions, settings: untouchedSettings(), isFocused: true)
        controller = PaneViewController(
            pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
            tableView: table, monitorsFolders: false)
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    }

    var deniedView: AccessDeniedView { controller.accessDeniedView }
}

extension ListingState {
    fileprivate var hasEnded: Bool {
        switch self {
        case .loading, .partial, .cachedRefreshing, .slow: false
        case .loaded, .offline, .denied, .failed, .notConnected, .serverListed: true
        }
    }
}

@MainActor @Test func aDeniedFolderShowsTheViewWithTheFolderName() async {
    let fixture = DeniedFixture(at: "/root/Mail")
    await settle { fixture.pane.state.hasEnded }

    #expect(!fixture.deniedView.isHidden)
    #expect(fixture.deniedView.titleLabel.stringValue.contains("“Mail”"))
    #expect(fixture.controller.messageLabel.isHidden)
    #expect(fixture.controller.status.spinner.isHidden)
}

@MainActor @Test func theButtonOpensFullDiskAccessInSystemSettings() async throws {
    let fixture = DeniedFixture(at: "/root/Mail")
    await settle { fixture.pane.state.hasEnded }

    fixture.deniedView.openSettingsButton.performClick(nil)

    let settings = try #require(
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"))
    #expect(fixture.actions.openedURLs == [settings])
}

/// Full Disk Access doesn't help with Unix permissions, so EACCES gets the error line too.
@MainActor @Test(arguments: ["/root/gone", "/root/locked"])
func otherFailuresShowTheErrorTextNotTheDeniedView(path: String) async {
    let fixture = DeniedFixture(at: path)
    await settle { fixture.pane.state.hasEnded }

    #expect(fixture.deniedView.isHidden)
    #expect(!fixture.controller.messageLabel.isHidden)
    #expect(fixture.controller.messageLabel.stringValue.contains(path))
}

@MainActor @Test func aMissingFolderShowsTheMissingStateWithItsPath() async {
    let fixture = DeniedFixture(at: "/root/gone")
    await settle { fixture.pane.state.hasEnded }

    #expect(fixture.controller.messageLabel.stringValue == "The folder /root/gone isn't there.")
    #expect(fixture.pane.location == Location(path: "/root/gone"))
}

@MainActor @Test func cmdUpFromADeniedFolderGoesBackAndHidesTheView() async throws {
    let fixture = DeniedFixture(at: "/root/Mail")
    await settle { fixture.pane.state.hasEnded }
    #expect(fixture.controller.keyView === fixture.table)

    fixture.table.keyDown(
        with: try keyEvent(
            functionKey(NSUpArrowFunctionKey), modifiers: [.numericPad, .function, .command]))
    await settle { fixture.pane.state.hasEnded }

    #expect(fixture.pane.location == Location(path: "/root"))
    #expect(fixture.deniedView.isHidden)
    #expect(fixture.pane.selection.members == .only([ExactName("Mail")]))
}

@MainActor @Test func aLongFolderNameTruncatesWithinTheViewsWidth() async {
    let name = String(repeating: "long name ", count: 14)
    let path = "/\(name)"
    let lister = GatedLister([path: .failure(ListingError(path: path, code: EPERM))])
    lister.releaseAll()
    let pane = Pane(
        location: Location(path: path), service: ListingService(lister: lister),
        systemActions: StubSystemActions(), settings: untouchedSettings(),
        isFocused: true)
    let controller = PaneViewController(
        pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
        tableView: ListingTableView(), monitorsFolders: false)
    await settle { pane.state.hasEnded }

    // Laid out as a window's content, as in the app; the window is never ordered in. Laid out
    // without a window, the view happened to keep its preferred width even before the fix.
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
        backing: .buffered, defer: true)
    window.contentView = controller.view
    window.layoutIfNeeded()

    // A label's frame is wider than its alignment rect, which is what the constraints size.
    func width(_ view: NSView) -> CGFloat { view.alignmentRect(forFrame: view.frame).width }
    let denied = controller.accessDeniedView
    #expect(name.count == 140)
    #expect(width(denied) <= 420)
    #expect(width(denied.titleLabel) <= width(denied))
    #expect(width(denied.explanationLabel) <= width(denied))
    #expect(denied.titleLabel.intrinsicContentSize.width > width(denied.titleLabel))
}

/// VoiceOver reads the button's title; the group's label names the folder.
@MainActor @Test func theViewIsAGroupLabeledWithTheFolderName() {
    let view = AccessDeniedView(systemActions: StubSystemActions())
    view.folderName = "Mail"

    #expect(view.isAccessibilityElement())
    #expect(view.accessibilityRole() == .group)
    #expect(view.accessibilityLabel()?.contains("“Mail”") == true)
    #expect(!view.openSettingsButton.title.isEmpty)
}
