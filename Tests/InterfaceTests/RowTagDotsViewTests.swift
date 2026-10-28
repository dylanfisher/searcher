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

/// Dylan, 2026-10-28: "make sure we use same colors as finder". Each tag is drawn in the system
/// color Finder now draws it in, not the older, lighter label colors
/// (docs/decisions/0127-tag-colors-and-pill-widths.md).
@MainActor @Test func eachTagsColorIsTheSystemColorFinderDrawsItIn() {
    #expect(
        FinderTag.all.map { NSColor.tagLabel($0.label) } == [
            .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple,
            .systemGray,
        ])
}

/// A row's dot, drawn in light mode, has the fill of Finder's dot of its color: the middle of
/// each of the seven in Dylan's screenshot of Finder's row menu, Display P3 0 to 255, whose
/// fills match Finder's row dots. Within 4 a component, the screenshot's JPEG noise.
@MainActor @Test func aRowsDotIsFilledAsFindersIs() throws {
    let finder: [Int: [CGFloat]] = [
        6: [240, 110, 108], 7: [244, 169, 104], 5: [248, 216, 104], 2: [131, 208, 131],
        4: [99, 158, 249], 3: [201, 100, 226], 1: [165, 164, 169],
    ]
    for (label, expected) in finder {
        let dots = RowTagDotsView()
        dots.appearance = NSAppearance(named: .aqua)
        dots.show([label])
        let bitmap = try #require(dots.bitmapImageRepForCachingDisplay(in: dots.bounds))
        dots.cacheDisplay(in: dots.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / dots.bounds.width
        let middle = dots.dotRect(at: 0)
        let pixel = try #require(
            bitmap.colorAt(x: Int(middle.midX * scale), y: Int(middle.midY * scale))?
                .usingColorSpace(.displayP3))
        let drawn = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent].map {
            $0 * 255
        }
        #expect(zip(drawn, expected).allSatisfy { abs($0 - $1) <= 4 }, "label \(label): \(drawn)")
    }
}

/// A dot's fill is its tag's color lightened in each appearance, so dark mode's dots take dark
/// mode's system colors.
@MainActor @Test func aDotsFillFollowsTheAppearance() throws {
    var fills: [NSColor] = []
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        let appearance = try #require(NSAppearance(named: name))
        var resolved: (dot: NSColor?, color: NSColor?)
        appearance.performAsCurrentDrawingAppearance {
            resolved = (
                NSColor.tagLabelDot(6).usingColorSpace(.displayP3),
                NSColor.tagLabel(6).usingColorSpace(.displayP3)
            )
        }
        let dot = try #require(resolved.dot)
        let color = try #require(resolved.color)
        let lightening = NSColor.tagDotLightening
        for (fill, base) in [
            (dot.redComponent, color.redComponent), (dot.greenComponent, color.greenComponent),
            (dot.blueComponent, color.blueComponent),
        ] {
            #expect(abs(fill - (base + lightening * (1 - base))) < 0.001)
        }
        fills.append(dot)
    }
    #expect(fills[0] != fills[1])
}
