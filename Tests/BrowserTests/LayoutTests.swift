import Browser
import Foundation
import TestSupport
import Testing

private let bounds = Rect(x: 0, y: 0, width: 1200, height: 800)
private let minimum = Layout.minimumPaneSize
private let divider = Layout.dividerThickness

/// Panes in the order a test built them, so expectations can name them by position.
private struct Built {
    var layout: Layout
    var panes: [PaneID]

    subscript(index: Int) -> PaneID { panes[index] }
}

private func split(_ built: inout Built, _ axis: Axis) {
    guard let new = built.layout.split(axis, in: bounds) else {
        Issue.record("split refused while building a fixture")
        return
    }
    built.panes.append(new)
}

/// p0 | p1 over p2: one tall pane, two stacked.
private func lShape() -> Built {
    var built = Built(layout: Layout(), panes: [])
    built.panes.append(built.layout.focused)
    split(&built, .horizontal)
    split(&built, .vertical)
    return built
}

/// p0 p1 over p2 p3.
private func grid() -> Built {
    var built = Built(layout: Layout(), panes: [])
    built.panes.append(built.layout.focused)
    split(&built, .horizontal)
    built.layout.focus(built[0])
    split(&built, .vertical)
    built.layout.focus(built[1])
    split(&built, .vertical)
    return built
}

/// Splits the focused pane and returns the new one, failing the test if the split is refused.
private func splitPane(_ layout: inout Layout, _ axis: Axis, in rect: Rect) throws -> PaneID {
    let new = layout.split(axis, in: rect)
    return try #require(new)
}

private func isClose(_ a: Double, _ b: Double) -> Bool {
    abs(a - b) < 1e-6
}

// MARK: Split and close

@Test func splitAddsPaneAfterFocusedAndFocusesIt() throws {
    var layout = Layout()
    let first = layout.focused
    let second = try splitPane(&layout, .horizontal, in: bounds)

    #expect(layout.panes == [first, second])
    #expect(layout.focused == second)
    #expect(layout.history == [second, first])
    let frames = layout.frames(in: bounds)
    #expect(try #require(frames[first]).maxX < (try #require(frames[second])).minX)
}

@Test func splitRefusesWhenHalvesWouldBeUnderMinimum() throws {
    let narrow = Rect(x: 0, y: 0, width: 2 * minimum + divider - 1, height: 800)
    var layout = Layout()
    let before = layout

    #expect(layout.split(.horizontal, in: narrow) == nil)
    #expect(layout == before)
    #expect(layout.split(.vertical, in: narrow) != nil)
}

@Test func splitRefusesOnceRepeatedSplitsReachMinimum() {
    var layout = Layout()
    var count = 1
    while layout.split(.horizontal, in: bounds) != nil {
        count += 1
    }
    // Each split halves the focused pane, so the last pane is the first to get too narrow.
    #expect(count == 4)
    for frame in layout.frames(in: bounds).values {
        #expect(frame.width >= minimum)
    }
}

@Test func closeCollapsesParentAndFocusesPreviousPane() {
    var built = lShape()
    built.layout.focus(built[0])
    built.layout.focus(built[2])

    #expect(built.layout.close() == built[2])
    #expect(built.layout.panes == [built[0], built[1]])
    #expect(built.layout.focused == built[0])
    #expect(
        built.layout.root
            == .split(
                axis: .horizontal, ratio: 0.5, first: .pane(built[0]), second: .pane(built[1])))
}

@Test func closingLastPaneIsRefused() {
    var layout = Layout()
    let before = layout

    #expect(layout.close() == nil)
    #expect(layout == before)
}

// MARK: Focus and move

@Test func focusByDirectionInGrid() {
    var built = grid()
    built.layout.focus(built[0])

    built.layout.focus(.right)
    #expect(built.layout.focused == built[1])
    built.layout.focus(.down)
    #expect(built.layout.focused == built[3])
    built.layout.focus(.left)
    #expect(built.layout.focused == built[2])
    built.layout.focus(.up)
    #expect(built.layout.focused == built[0])
    built.layout.focus(.up)
    #expect(built.layout.focused == built[0])
}

@Test func focusLeftFromStackGoesToTallPane() {
    var built = lShape()
    built.layout.focus(.left)
    #expect(built.layout.focused == built[0])
}

@Test func focusRightFromTallPanePrefersMostRecent() {
    var built = lShape()
    built.layout.focus(built[1])
    built.layout.focus(built[0])
    built.layout.focus(.right)
    #expect(built.layout.focused == built[1])

    built.layout.focus(built[2])
    built.layout.focus(built[0])
    built.layout.focus(.right)
    #expect(built.layout.focused == built[2])
}

@Test func historyIsMostRecentFirst() {
    var built = grid()
    built.layout.focus(built[2])
    built.layout.focus(built[1])
    built.layout.focus(built[3])
    #expect(built.layout.history == [built[3], built[1], built[2], built[0]])
}

// MARK: Other pane

@Test func otherPaneIsTheMostRecentlyFocusedOtherLeafNotTheNearest() {
    // p0 | p1 | p2: p1 is p2's neighbor, but p0 was focused after it.
    var built = Built(layout: Layout(), panes: [])
    built.panes.append(built.layout.focused)
    split(&built, .horizontal)
    split(&built, .horizontal)
    built.layout.focus(built[1])
    built.layout.focus(built[0])
    built.layout.focus(built[2])

    #expect(built.layout.otherPane == built[0])
}

@Test func otherPaneFollowsFocusMovesAndCloses() {
    var built = grid()
    built.layout.focus(built[0])
    built.layout.focus(built[1])
    built.layout.focus(built[2])
    #expect(built.layout.otherPane == built[1])

    built.layout.move(.right)
    #expect(built.layout.otherPane == built[1])

    built.layout.focus(built[1])
    #expect(built.layout.otherPane == built[2])

    built.layout.close()
    #expect(built.layout.focused == built[2])
    #expect(built.layout.otherPane == built[0])
}

@Test func oneLeafHasNoOtherPane() {
    #expect(Layout().otherPane == nil)
}

@Test func moveSwapsWithNeighborAndKeepsFocus() {
    var built = grid()
    built.layout.focus(built[0])
    built.layout.move(.right)

    #expect(built.layout.focused == built[0])
    #expect(built.layout.neighbor(of: built[0], .left) == built[1])
    #expect(built.layout.neighbor(of: built[0], .down) == built[3])
}

// MARK: Resize, ratios and equalize

@Test func resizeMovesNearestDividerOnThatAxisByPoints() throws {
    var built = lShape()
    built.layout.resize(.down, by: 40, in: bounds)

    let frames = built.layout.frames(in: bounds)
    let top = try #require(frames[built[1]])
    #expect(isClose(top.height, (800 - divider) / 2 + 40))
    #expect(isClose(try #require(frames[built[0]]).width, (1200 - divider) / 2))
}

@Test func resizeMovesTheDividerOnTheRightEdgeWhateverTheTreesShape() throws {
    // (p0 | p1) | p2: the innermost split holding p1 is p0 | p1, on its left edge, but ← moves
    // the divider on its right edge, as it does in p0 | (p1 | p2).
    var layout = Layout()
    let p0 = layout.focused
    let p2 = try splitPane(&layout, .horizontal, in: bounds)
    layout.focus(p0)
    let p1 = try splitPane(&layout, .horizontal, in: bounds)
    let before = try #require(layout.frames(in: bounds)[p1])

    layout.resize(.left, by: 40, in: bounds)

    let frames = layout.frames(in: bounds)
    #expect(isClose(try #require(frames[p1]).maxX, before.maxX - 40))
    #expect(isClose(try #require(frames[p2]).width, (1200 - divider) / 2 + 40))
}

@Test func resizeClampsAtMinimumPaneSize() throws {
    var built = lShape()
    built.layout.resize(.right, by: 10_000, in: bounds)
    built.layout.resize(.up, by: 10_000, in: bounds)

    let frames = built.layout.frames(in: bounds)
    #expect(isClose(try #require(frames[built[1]]).width, minimum))
    #expect(isClose(try #require(frames[built[1]]).height, minimum))
    #expect(isClose(try #require(frames[built[2]]).width, minimum))
}

@Test func resizePushesNestedDividersButKeepsEveryPaneAtMinimum() throws {
    // p0 | p1 | p2, with p1 | p2 nested: pushing the outer divider right squeezes both.
    var layout = Layout()
    let p0 = layout.focused
    let p1 = try splitPane(&layout, .horizontal, in: bounds)
    let p2 = try splitPane(&layout, .horizontal, in: bounds)
    layout.focus(p0)
    layout.resize(.right, by: 10_000, in: bounds)

    let frames = layout.frames(in: bounds)
    #expect(isClose(try #require(frames[p1]).width, minimum))
    #expect(isClose(try #require(frames[p2]).width, minimum))
    #expect(isClose(try #require(frames[p0]).width, 1200 - 2 * minimum - 2 * divider))
}

@Test func dragOnDividerSetsRatioAndClamps() throws {
    var built = lShape()
    let outer = try #require(built.layout.dividers(in: bounds).first { $0.path.isEmpty })
    let ratio = outer.ratio(at: 300)
    built.layout.setRatio(ratio, at: outer.path, in: bounds)
    #expect(isClose(try #require(built.layout.frames(in: bounds)[built[0]]).width, 300))

    built.layout.setRatio(outer.ratio(at: 5), at: outer.path, in: bounds)
    #expect(isClose(try #require(built.layout.frames(in: bounds)[built[0]]).width, minimum))
}

@Test func equalizeGivesEqualWidthToSameAxisRun() throws {
    var layout = Layout()
    let p0 = layout.focused
    let p1 = try splitPane(&layout, .horizontal, in: bounds)
    let p2 = try splitPane(&layout, .horizontal, in: bounds)
    layout.equalize(in: bounds)

    let frames = layout.frames(in: bounds)
    for pane in [p0, p1, p2] {
        #expect(isClose(try #require(frames[pane]).width, (1200 - 2 * divider) / 3))
    }
}

@Test func equalizeKeepsMinimumWhereEqualSharesWouldNot() throws {
    // p0 | (p1 over p2 | p3 | p4): equal shares give each side 299.5 pt, but the three-pane row
    // needs 362.
    let narrow = Rect(x: 0, y: 0, width: 600, height: 800)
    var layout = Layout()
    let p0 = layout.focused
    _ = try splitPane(&layout, .horizontal, in: narrow)
    layout.resize(.left, by: 10_000, in: narrow)
    _ = try splitPane(&layout, .vertical, in: narrow)
    let p2 = layout.focused
    let p3 = try splitPane(&layout, .horizontal, in: narrow)
    layout.focus(p2)
    layout.resize(.left, by: 10_000, in: narrow)
    layout.focus(p3)
    let p4 = try splitPane(&layout, .horizontal, in: narrow)
    layout.equalize(in: narrow)

    let frames = layout.frames(in: narrow)
    #expect(isClose(try #require(frames[p0]).width, 600 - divider - (3 * minimum + 2 * divider)))
    for pane in [p2, p3, p4] {
        #expect(isClose(try #require(frames[pane]).width, minimum))
    }
}

// MARK: Zoom

@Test func zoomGivesFocusedPaneWholeRectAndSplitEndsIt() {
    var built = grid()
    built.layout.toggleZoom()

    #expect(built.layout.isZoomed)
    #expect(built.layout.frames(in: bounds) == [built.layout.focused: bounds])
    #expect(built.layout.dividers(in: bounds).isEmpty)
    _ = built.layout.split(.vertical, in: bounds)
    #expect(!built.layout.isZoomed)
}

@Test func focusingAnotherPaneEndsZoom() {
    var built = grid()
    built.layout.focus(built[0])
    built.layout.toggleZoom()
    built.layout.focus(.right)

    #expect(built.layout.focused == built[1])
    #expect(!built.layout.isZoomed)
}

// MARK: Geometry and storage

@Test func framesAndDividersTileTheRect() {
    let built = grid()
    let frames = built.layout.frames(in: bounds)
    let dividers = built.layout.dividers(in: bounds)
    let area =
        frames.values.reduce(0) { $0 + $1.width * $1.height }
        + dividers.reduce(0) { $0 + $1.rect.width * $1.rect.height }

    #expect(dividers.count == 3)
    #expect(isClose(area, 1200 * 800))
}

@Test func jsonRoundTrip() throws {
    var built = grid()
    built.layout.resize(.left, by: 60, in: bounds)
    built.layout.toggleZoom()

    let data = try JSONEncoder().encode(built.layout)
    #expect(try JSONDecoder().decode(Layout.self, from: data) == built.layout)
}

@Test func decodingRejectsFocusOutsideTheTree() throws {
    let built = grid()
    var json = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(built.layout)) as? [String: Any])
    json["focused"] = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(PaneID()), options: .fragmentsAllowed)
    let data = try JSONSerialization.data(withJSONObject: json)

    #expect(throws: DecodingError.self) { try JSONDecoder().decode(Layout.self, from: data) }
}

// MARK: Random edits

/// Random edits keep every pane listed once, focus and history valid, frames and dividers tiling
/// the rect, and every pane at least the minimum size.
@Test(arguments: 0..<200) func randomEditsKeepInvariants(seed: Int) {
    var random = SeededGenerator(seed: UInt64(seed))
    var layout = Layout()
    for _ in 0..<(12 + seed % 30) {
        let direction = Direction.allCases.randomElement(using: &random)!
        switch Int.random(in: 0..<8, using: &random) {
        case 0, 1:
            _ = layout.split(Bool.random(using: &random) ? .horizontal : .vertical, in: bounds)
        case 2: _ = layout.close()
        case 3: layout.focus(direction)
        case 4: layout.move(direction)
        case 5:
            layout.resize(direction, by: Double.random(in: 10...400, using: &random), in: bounds)
        case 6:
            if let drag = layout.dividers(in: bounds).randomElement(using: &random) {
                layout.setRatio(Double.random(in: 0...1, using: &random), at: drag.path, in: bounds)
            } else {
                layout.toggleZoom()
            }
        default: layout.equalize(in: bounds)
        }

        let panes = layout.panes
        #expect(Set(panes).count == panes.count)
        #expect(layout.history.first == layout.focused)
        #expect(Set(layout.history) == Set(panes) && layout.history.count == panes.count)

        let frames = layout.frames(in: bounds)
        let dividers = layout.dividers(in: bounds)
        let area =
            frames.values.reduce(0) { $0 + $1.width * $1.height }
            + dividers.reduce(0) { $0 + $1.rect.width * $1.rect.height }
        #expect(isClose(area, 1200 * 800))
        for frame in frames.values {
            #expect(frame.width >= minimum - 1e-9 && frame.height >= minimum - 1e-9)
        }
    }
}
