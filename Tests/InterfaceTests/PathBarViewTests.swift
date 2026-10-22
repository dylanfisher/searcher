import AppKit
import Browser
import Testing

@testable import Interface

@MainActor
private func pathBar(
    showing path: String, rootVolumeName: String = "Macintosh HD", width: CGFloat = 800
) -> PathBarView {
    let bar = PathBarView()
    bar.frame = NSRect(x: 0, y: 0, width: width, height: PathBarView.height)
    bar.show(Location(path: path), rootVolumeName: rootVolumeName)
    bar.layoutSubtreeIfNeeded()
    return bar
}

@MainActor @Test func segmentsNameTheVolumeThenEachFolder() {
    let bar = pathBar(showing: "/Users/dylan/Projects", rootVolumeName: "Work Disk")

    #expect(bar.segments.map(\.title) == ["Work Disk", "Users", "dylan", "Projects"])
}

@MainActor @Test func rootShowsOnlyTheVolume() {
    let bar = pathBar(showing: "/")

    #expect(bar.segments.map(\.title) == ["Macintosh HD"])
}

@MainActor @Test func clickingASegmentReportsItsFolderAndTheChildItCameFrom() throws {
    let bar = pathBar(showing: "/Users/dylan/Projects")
    var selected: [(Location, String)] = []
    bar.onSelect = { selected.append(($0, $1)) }

    bar.segments[1].performClick(nil)

    let only = try #require(selected.first)
    #expect(selected.count == 1)
    #expect(only.0 == Location(path: "/Users"))
    #expect(only.1 == "dylan")
}

@MainActor @Test func clickingTheCurrentFolderReportsNothing() {
    let bar = pathBar(showing: "/Users/dylan")
    var selected: [Location] = []
    bar.onSelect = { location, _ in selected.append(location) }

    bar.segments[2].performClick(nil)

    #expect(selected.isEmpty)
}

@MainActor @Test func aLongPathTruncatesMiddleSegmentsFirst() {
    let path = "/Users/dylan/a fairly long folder name/another fairly long folder name/Projects"
    let wide = pathBar(showing: path, width: 2000)
    let natural = wide.segments.map(\.frame.width)

    let narrow = pathBar(showing: path, width: natural.reduce(0, +) - 60)
    let widths = narrow.segments.map(\.frame.width)

    #expect(widths.first == natural.first)
    #expect(widths.last == natural.last)
    #expect(zip(widths, natural).dropFirst().dropLast().contains { $0 < $1 })
    #expect(narrow.segments.allSatisfy { $0.frame.maxX <= narrow.bounds.maxX })
}

@MainActor @Test func aRowTooLongForTheBarIsClippedToIt() {
    let bar = pathBar(showing: "/a/b/c/d/e/f/g/h/i/j/k", width: 100)

    #expect(bar.segments.last.map { $0.frame.maxX > bar.bounds.maxX } == true)
    #expect(bar.clipsToBounds)
}

@Test func widthsComeOutOfTheMiddleBeforeTheEnds() {
    // Middle segments go down to the minimum, nearest the root first, before either end shrinks.
    #expect(
        PathBarView.widths(natural: [50, 80, 80, 60], available: 230, minimum: 30)
            == [50, 40, 80, 60])
    #expect(
        PathBarView.widths(natural: [50, 80, 80, 60], available: 150, minimum: 30)
            == [30, 30, 30, 60])
    #expect(
        PathBarView.widths(natural: [50, 80], available: 200, minimum: 30) == [50, 80])
}

@MainActor @Test func cmdClickingASegmentOpensItsFolderInANewTabInsteadOfSelectingIt() {
    let bar = pathBar(showing: "/Users/dylan/Projects")
    bar.currentModifierFlags = { .command }
    var selected: [Location] = []
    var opened: [Location] = []
    bar.onSelect = { location, _ in selected.append(location) }
    bar.onOpenInNewTab = { opened.append($0) }

    bar.segments[1].performClick(nil)
    // The current folder too: it is a folder to open, though a plain click there does nothing.
    bar.segments[3].performClick(nil)

    #expect(opened == [Location(path: "/Users"), Location(path: "/Users/dylan/Projects")])
    #expect(selected.isEmpty)
}
