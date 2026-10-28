import AppKit
import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

// A tagged item's row shows its tags' colors as dots after its name, as Finder does, in a list
// and in a column, driven through a real window over a real temporary folder
// (`TaggingWindow`); the tags come from the listing (docs/decisions/0124-tags-in-rows-and-
// preview.md).

extension TaggingWindow {
    /// The Name cell of `name`'s row.
    func nameCell(of name: String) throws -> ListingNameCellView {
        let cell = try list.shownNameCell(atRow: try row(of: name))
        return try #require(cell as? ListingNameCellView)
    }

    /// The tag dots `name`'s row shows, nil when it shows none.
    func rowDots(of name: String) throws -> RowTagDotsView? {
        try nameCell(of: name).tagDots.flatMap { $0.isHidden ? nil : $0 }
    }
}

@MainActor @Test(arguments: [ViewMode.list, .column])
func aTaggedRowShowsItsTagColorsAfterItsNameAndAnUntaggedRowNone(_ viewMode: ViewMode)
    async throws
{
    let window = try await TaggingWindow(
        [("a.txt", ["Orange\n7", "Work", "Red\n6"]), ("b.txt", []), ("c.txt", ["Work\n0"])],
        viewMode: viewMode)

    let dots = try #require(try window.rowDots(of: "a.txt"))
    #expect(dots.labels == [7, 6])
    // An untagged row, and one whose only tag has no color, as in Finder.
    #expect(try window.rowDots(of: "b.txt") == nil)
    #expect(try window.rowDots(of: "c.txt") == nil)

    let cell = try window.nameCell(of: "a.txt")
    let name = try #require(cell.textField)
    // After the whole name, a gap before the first dot.
    #expect(name.frame.width >= name.intrinsicContentSize.width)
    #expect(dots.frame.minX >= name.frame.maxX)
    #expect(dots.frame.minX - name.frame.maxX <= ListingCellLayout.tagDotsGap)
    #expect(dots.frame.size == RowTagDotsView.size(count: 2))
    #expect(abs(dots.frame.midY - cell.bounds.midY) <= 0.5)
    // The rename field covers the name and stops before the dots.
    let list = try window.list
    let nameFrame = list.nameFrame(atRow: try window.row(of: "a.txt"))
    #expect(nameFrame.maxX <= list.tableView.convert(dots.frame, from: cell).minX)
    // VoiceOver hears the colors.
    let rowView = try #require(
        list.tableView.rowView(atRow: try window.row(of: "a.txt"), makeIfNecessary: false))
    #expect(rowView.accessibilityLabel()?.contains("tags Orange, Red") == true)
}

/// A name too long for its cell truncates before the dots, which keep their place: in a column
/// left of where a folder's chevron goes, as Finder lines them up; in a list at the cell's end.
@MainActor @Test(arguments: [ViewMode.list, .column])
func aLongNameTruncatesBeforeTheDots(_ viewMode: ViewMode) async throws {
    let long = String(repeating: "Screenshot ", count: 20) + ".jpg"
    let window = try await TaggingWindow([(long, ["Yellow\n5"])], viewMode: viewMode)

    let dots = try #require(try window.rowDots(of: long))
    let cell = try window.nameCell(of: long)
    let name = try #require(cell.textField)

    #expect(name.frame.width < name.intrinsicContentSize.width)
    #expect(name.frame.maxX <= dots.frame.minX)
    let end =
        ListingCellLayout.chevron(in: cell) != nil
        ? cell.bounds.width
            - ListingCellLayout.chevronRoom(for: try window.list.tableView.selectionShape)
            - ListingCellLayout.tagDotsGap
        : cell.bounds.width - 2
    #expect(abs(dots.frame.maxX - end) <= 0.5)
}

/// Tags set by another app reach the row through the folder's FSEvents patch, as the preview's
/// do.
@MainActor @Test(arguments: [ViewMode.list, .column])
func aTagChangeUpdatesTheRow(_ viewMode: ViewMode) async throws {
    let window = try await TaggingWindow(
        [("a.txt", []), ("b.txt", ["Green\n2"])], viewMode: viewMode, monitorsFolders: true)
    #expect(try window.rowDots(of: "a.txt") == nil)

    try await setTags(["Blue\n4", "Purple\n3"], at: window.path("a.txt"))
    try await setTags([], at: window.path("b.txt"))

    await settle { (try? window.rowDots(of: "a.txt"))??.labels == [4, 3] }
    await settle { (try? window.rowDots(of: "b.txt")) == .some(nil) }
    #expect(try window.rowDots(of: "a.txt")?.labels == [4, 3])
    #expect(try window.rowDots(of: "b.txt") == nil)
}

@MainActor @Test func aRowShowsAtMostThreeDotsOverlappingByHalf() {
    let dots = RowTagDotsView()

    dots.show([6, 7, 5, 2, 4])

    #expect(dots.labels == [6, 7, 5])
    #expect(dots.frame.size == RowTagDotsView.size(count: 3))
    #expect(dots.dotRect(at: 1).minX - dots.dotRect(at: 0).minX == RowTagDotsView.diameter / 2)
    #expect(dots.dotRect(at: 2).maxX + RowTagDotsView.outline == dots.bounds.maxX)
}

/// On an emphasized selection the dots take a white outline, as Finder's do.
@MainActor @Test func aSelectedRowsDotsHaveAWhiteOutline() async throws {
    let window = try await TaggingWindow([("a.txt", ["Blue\n4"])])
    let cell = try window.nameCell(of: "a.txt")
    let dots = try #require(try window.rowDots(of: "a.txt"))

    cell.backgroundStyle = .emphasized
    #expect(dots.isOnEmphasizedSelection)
    cell.backgroundStyle = .normal
    #expect(!dots.isOnEmphasizedSelection)
}
