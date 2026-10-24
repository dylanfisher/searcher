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

@MainActor @Test func separatorsFitTheirGlyphAndCenterOnTheText() throws {
    let bar = pathBar(showing: "/Users/dylan/Projects")
    let separators = bar.subviews.filter { !($0 is NSButton) }
    let segment = bar.segments[0]
    let font = try #require(segment.font)
    // The middle of a capital letter, which Finder's chevrons line up with.
    let baseline = segment.frame.maxY - segment.firstBaselineOffsetFromTop
    let textMiddle = baseline + font.capHeight / 2

    // A taller button draws its title lower than its baseline offset says.
    #expect(segment.frame.height == ceil(segment.intrinsicContentSize.height))
    #expect(separators.count == 3)
    for separator in separators {
        let natural = separator.frame(
            forAlignmentRect: NSRect(origin: .zero, size: separator.intrinsicContentSize))
        #expect(separator.frame.width >= natural.width)
        #expect(separator.frame.height >= natural.height)
        #expect(bar.bounds.contains(separator.frame))
        #expect(abs(separator.frame.midY - textMiddle) <= 1)
    }
}

@MainActor private func mouseEvent(_ type: NSEvent.EventType) throws -> NSEvent {
    try #require(
        NSEvent.enterExitEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
}

@MainActor @Test func eachSegmentTracksTheMouse() {
    let bar = pathBar(showing: "/Users/dylan/Projects")

    #expect(
        bar.segments.allSatisfy { segment in
            segment.trackingAreas.contains { $0.options.contains(.mouseEnteredAndExited) }
        })
}

@MainActor @Test func aSegmentIsHighlightedWhileTheMouseIsOverIt() throws {
    let bar = pathBar(showing: "/Users/dylan/Projects")

    bar.segments[1].mouseEntered(with: try mouseEvent(.mouseEntered))
    #expect(bar.hoveredSegment == 1)

    bar.segments[1].mouseExited(with: try mouseEvent(.mouseExited))
    #expect(bar.hoveredSegment == nil)
}

@MainActor @Test func theHighlightSitsBehindTheHoveredSegment() throws {
    let bar = pathBar(showing: "/Users/dylan/Projects")
    #expect(bar.highlightFrame == nil)

    bar.segments[2].mouseEntered(with: try mouseEvent(.mouseEntered))

    let highlight = try #require(bar.highlightFrame)
    let segment = bar.segments[2].frame
    #expect(highlight.minX == segment.minX && highlight.maxX == segment.maxX)
    #expect(highlight.minY < segment.minY && highlight.maxY > segment.maxY)
}

@MainActor @Test func showingAnotherFolderClearsTheHighlight() throws {
    let bar = pathBar(showing: "/Users/dylan/Projects")
    bar.segments[2].mouseEntered(with: try mouseEvent(.mouseEntered))

    bar.show(Location(path: "/Users/dylan"), rootVolumeName: "Macintosh HD")

    #expect(bar.hoveredSegment == nil)
}

@MainActor @Test func theRowStartsAtTheSharedBarInset() {
    let bar = pathBar(showing: "/Users/dylan/Projects")

    #expect(bar.segments.first?.frame.minX == BarInset.horizontal)
}

/// A bar `cut` points too narrow for its row, so its middle folders truncate, and each
/// segment's natural width.
@MainActor private func truncatedPathBar(cut: CGFloat = 120) -> (PathBarView, [CGFloat]) {
    let path = "/Users/dylan/a fairly long folder name/another fairly long folder name/Projects"
    let wide = pathBar(showing: path, width: 4000)
    let natural = wide.segments.map(\.frame.width)
    let rowWidth = (wide.segments.last?.frame.maxX ?? 0) + BarInset.horizontal
    return (pathBar(showing: path, width: rowWidth - cut), natural)
}

@MainActor @Test func aHoveredTruncatedSegmentTakesItsFullWidthAndTheOthersGiveWay() throws {
    let (bar, natural) = truncatedPathBar()
    let truncated = try #require(
        bar.segments.indices.last { bar.segments[$0].frame.width < natural[$0] })
    let end = bar.segments.last?.frame.maxX

    bar.segments[truncated].mouseEntered(with: try mouseEvent(.mouseEntered))
    bar.layoutSubtreeIfNeeded()

    #expect(bar.segments[truncated].frame.width == natural[truncated])
    #expect(bar.segments.last?.frame.maxX == end)
    #expect(
        bar.segments.indices.contains {
            $0 != truncated && bar.segments[$0].frame.width < natural[$0]
        })

    bar.segments[truncated].mouseExited(with: try mouseEvent(.mouseExited))
    bar.layoutSubtreeIfNeeded()
    #expect(bar.segments[truncated].frame.width < natural[truncated])
}

@MainActor @Test func onlyTruncatedSegmentsHaveATooltipWithTheirFullName() {
    let (bar, natural) = truncatedPathBar()

    for (index, segment) in bar.segments.enumerated() {
        let isTruncated = segment.frame.width < natural[index]
        #expect(segment.toolTip == (isTruncated ? segment.title : nil))
    }
    #expect(bar.segments.contains { $0.toolTip != nil })
    #expect(bar.segments.contains { $0.toolTip == nil })
}

@Test func anExpandedSegmentKeepsItsWidthWhileTheOthersShrink() {
    // The second middle segment keeps its 80; the first middle one, then the root, give way.
    #expect(
        PathBarView.widths(natural: [50, 80, 80, 60], available: 200, minimum: 30, expanding: 2)
            == [30, 30, 80, 60])
    // It gives way last, once every other segment is at the minimum.
    #expect(
        PathBarView.widths(natural: [50, 80, 80, 60], available: 140, minimum: 30, expanding: 2)
            == [30, 30, 50, 30])
}
