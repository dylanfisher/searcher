import AppKit
import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

/// Dates in UTC and English, so a column's row label and the list's read the same.
@MainActor
private let formatter = EntryCellFormatter(
    locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)

/// `/Volumes/r`, a volume, so its trail starts there, holds a folder `docs` and a file `a.txt`;
/// `/Volumes/r/docs` holds a folder `sub` and two files; `/Volumes/r/docs/sub` holds a FLAC file.
private let tree: [String: [DirectoryEntry]] = [
    "/": [folder("r")],
    "/Volumes/r": [folder("docs"), file("a.txt")],
    "/Volumes/r/docs": [folder("sub"), file("x.txt", size: 2_000_000), file("y.pdf")],
    "/Volumes/r/docs/sub": [file("one.flac")],
]

/// One accessibility notification the column view would have posted.
private struct Post {
    let element: Any
    let notification: NSAccessibility.Notification
}

/// A pane at `/Volumes/r` in column mode with `/Volumes/r/docs/sub` open in three columns, the
/// first focused, shown by a column view that is never put in a window. Its notifications are
/// recorded rather than posted.
@MainActor
private final class Fixture {
    let pane: Pane
    let controller: ColumnViewController
    private(set) var posts: [Post] = []

    init() async {
        pane = Pane(
            location: Location(path: "/Volumes/r"),
            service: ListingService(lister: StubLister(tree), rootVolumeName: { "Test Disk" }),
            systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true,
            viewMode: .column)
        controller = ColumnViewController(
            pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: formatter)
        controller.startMonitor = { _ in }
        controller.postAccessibility = { [unowned self] element, notification, _ in
            posts.append(Post(element: element, notification: notification))
        }
        pane.onChange = { [weak controller] in controller?.paneDidChange() }
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        let trail = trail
        await settle { trail.focused.pane.state.isLoaded }
        await select("docs", inColumn: 0)
        await select("sub", inColumn: 1)
    }

    var trail: ColumnTrail {
        guard let trail = pane.columnTrail else {
            preconditionFailure("the pane isn't in column mode")
        }
        return trail
    }

    var tables: [ListingTableView] { controller.columnControllers.map(\.tableView) }

    /// Selects `name` alone in the column at `index`, and waits for the column it opens to load
    /// and for a file's preview to show once its info is read.
    func select(_ name: String, inColumn index: Int) async {
        trail.columns[index].pane.select(Selection([ExactName(name)], cursor: ExactName(name)))
        let trail = trail
        await settle {
            trail.columns.allSatisfy { $0.pane.state.isLoaded }
                && trail.shownPreview == trail.preview
        }
    }

    var focusChanges: [Post] { posts.filter { $0.notification == .focusedUIElementChanged } }
}

/// Each column is followed by its resize grip, and the preview by its own.
@MainActor @Test func theColumnsAndTheirGripsAreABrowsersChildrenInOrder() async throws {
    let fixture = await Fixture()
    let browser = fixture.controller.columnsView
    let controller = fixture.controller

    #expect(browser.isAccessibilityElement())
    #expect(browser.accessibilityRole() == .browser)
    let children = try #require(browser.accessibilityChildren() as? [NSView])
    let expected = try (0..<3).flatMap { index in
        [
            controller.columnControllers[index].view,
            try #require(controller.grip(forColumnAt: index)),
        ]
    }
    #expect(children.count == 6)
    #expect(zip(children, expected).allSatisfy { $0 === $1 })

    await fixture.select("a.txt", inColumn: 0)

    // The file's preview and its grip follow the columns.
    let remaining = try #require(browser.accessibilityChildren() as? [NSView])
    #expect(remaining.count == 4)
    #expect(remaining.first === controller.columnControllers[0].view)
    #expect(remaining[2] === controller.previewView)
    #expect(remaining[3] === controller.previewGrip)

    await fixture.select("docs", inColumn: 0)

    let folders = try #require(browser.accessibilityChildren() as? [NSView])
    #expect(folders.count == 4)
    #expect(!folders.contains { $0 is ColumnPreviewView })
    #expect(!folders.contains { $0 === controller.previewGrip })
}

/// A grip is named for its column's folder, and the preview's for the preview.
@MainActor @Test func eachGripIsLabeledWithItsColumnsFolderName() async throws {
    let fixture = await Fixture()
    let controller = fixture.controller

    let labels = (0..<3).map { controller.grip(forColumnAt: $0)?.accessibilityLabel() }

    #expect(labels == ["r column width", "docs column width", "sub column width"])
    await fixture.select("one.flac", inColumn: 2)
    #expect(controller.previewGrip?.accessibilityLabel() == ColumnGripView.previewLabel)
}

/// VoiceOver resizes the column it is on, and hears the new width.
@MainActor @Test func aGripsIncrementWidensItsColumnAndReportsTheValue() async throws {
    let fixture = await Fixture()
    let controller = fixture.controller
    let grip = try #require(controller.grip(forColumnAt: 1))

    #expect(grip.accessibilityPerformIncrement())

    let widened = Settings.defaultColumnWidth + ColumnGripView.accessibilityStep
    #expect(Double(controller.columnControllers[1].view.frame.width) == widened)
    #expect(grip.accessibilityValue() as? NSNumber == NSNumber(value: widened))
    #expect(Double(controller.columnControllers[0].view.frame.width) == Settings.defaultColumnWidth)
    #expect(
        fixture.posts.contains {
            ($0.element as? NSView) === grip && $0.notification == .valueChanged
        })
}

@MainActor @Test func eachColumnIsLabeledWithItsFolderName() async throws {
    let fixture = await Fixture()

    let labels = fixture.controller.columnControllers.map { $0.view.accessibilityLabel() }

    #expect(labels == ["r", "docs", "sub"])
}

/// A column formats from the entry what the list reads from its other cells; both have to say
/// the same thing (0040-list-accessibility.md).
@MainActor @Test func aColumnsRowLabelsMatchTheListsForTheSameFolder() async throws {
    let fixture = await Fixture()
    let column = fixture.controller.columnControllers[1]
    column.view.layoutSubtreeIfNeeded()
    let listPane = Pane(
        location: Location(path: "/Volumes/r/docs"),
        service: ListingService(lister: StubLister(tree), rootVolumeName: { "Test Disk" }),
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: false)
    let list = ListingViewController(
        pane: listPane, iconCache: TypeIconCache { _ in NSImage() }, formatter: formatter,
        tableView: ListingTableView())
    listPane.onChange = { [weak list] in list?.paneDidChange() }
    list.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 400)
    await settle { listPane.state.isLoaded }
    list.view.layoutSubtreeIfNeeded()

    let rows = try #require(column.listing).count
    #expect(rows == 3)
    for row in 0..<rows {
        let columnLabel = column.tableView.rowView(atRow: row, makeIfNecessary: false)?
            .accessibilityLabel()
        let listLabel = list.tableView.rowView(atRow: row, makeIfNecessary: false)?
            .accessibilityLabel()
        #expect(columnLabel != nil)
        #expect(columnLabel == listLabel)
    }
}

@MainActor @Test func focusingAnotherColumnPostsAFocusChangeOnItsTable() async throws {
    let fixture = await Fixture()
    #expect(fixture.focusChanges.isEmpty)

    fixture.trail.moveRight()

    #expect(fixture.focusChanges.count == 1)
    #expect(fixture.focusChanges.last?.element as? NSTableView === fixture.tables[1])

    fixture.trail.moveLeft()

    #expect(fixture.focusChanges.count == 2)
    #expect(fixture.focusChanges.last?.element as? NSTableView === fixture.tables[0])
}

@MainActor @Test func aSelectionChangeInsideTheFocusedColumnPostsNoFocusChange() async throws {
    let fixture = await Fixture()

    await fixture.select("a.txt", inColumn: 0)

    #expect(fixture.focusChanges.isEmpty)
}

/// A click gives the table the keys, and AppKit reports that focus change itself.
@MainActor @Test func aColumnFocusedByItsTableTakingTheKeysPostsNoSecondFocusChange() async throws {
    let fixture = await Fixture()
    let window = testWindow(size: NSSize(width: 800, height: 400))
    window.contentView?.addSubview(fixture.controller.view)

    #expect(window.makeFirstResponder(fixture.tables[2]))

    #expect(fixture.trail.focusedIndex == 2)
    #expect(fixture.focusChanges.isEmpty)
}

@MainActor @Test func thePreviewIsAGroupNamedForItsFileThatReadsItsFields() async throws {
    let fixture = await Fixture()
    let reader = GatedItemInfoReader([
        "/Volumes/r/docs/x.txt": ItemInfo(created: testDate, lastOpened: testDate, tags: ["Red"])
    ])
    reader.releaseAll()
    fixture.pane.itemInfoReader = reader

    await fixture.select("x.txt", inColumn: 1)

    let view = try #require(fixture.controller.previewView)
    await settle { !view.tagPills.isHidden }
    let kind = try #require(fixture.trail.preview?.kind.text)
    #expect(view.isAccessibilityElement())
    #expect(view.accessibilityRole() == .group)
    #expect(view.accessibilityLabel() == "x.txt")
    let fields = try #require(view.accessibilityChildren() as? [NSTextField])
    let date = formatter.longDate(testDate, style: view.dateStyle)
    #expect(
        fields.map(\.stringValue) == [
            "x.txt", "\(kind) - 2 MB", "Information", "Created", date,
            "Modified", date, "Last opened", date, "Tags", "Red",
        ])
}
