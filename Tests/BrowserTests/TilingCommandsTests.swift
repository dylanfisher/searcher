import Base
import Foundation
import TestSupport
import Testing

@testable import Browser

private let bounds = Rect(x: 0, y: 0, width: 1200, height: 800)
private let tolerance = 1e-9

/// A workspace of one tab, whose load at `/r` is held so nothing finishes during a test.
@MainActor
private func oneTabWorkspace() -> Workspace {
    Workspace(tab: Tab(pane: PaneFixture(at: "/r", folders: ["/r": []], held: true).pane))
}

/// The tab's four panes in a 2×2 grid, D focused:
///
///     A | B
///     --+--
///     C | D
@MainActor
private struct Grid {
    let workspace = oneTabWorkspace()
    let a: PaneID
    let b: PaneID
    let c: PaneID
    let d: PaneID

    init() throws {
        let tab = workspace.selectedTab
        a = tab.layout.focused
        try #require(tab.split(.horizontal, in: bounds) != nil)
        b = tab.layout.focused
        tab.focus(a)
        try #require(tab.split(.vertical, in: bounds) != nil)
        c = tab.layout.focused
        tab.focus(b)
        try #require(tab.split(.vertical, in: bounds) != nil)
        d = tab.layout.focused
    }

    var tab: Tab { workspace.selectedTab }
    var frames: [PaneID: Rect] { tab.layout.frames(in: bounds) }
}

/// Runs the command bound to `chord` on `workspace`'s selected tab, as the window would, and
/// returns what a close reported.
@MainActor
@discardableResult
private func press(_ chord: KeyChord, in workspace: Workspace) throws -> CloseResult? {
    var registry = CommandRegistry()
    for binding in TilingCommands.bindings {
        try registry.register(binding.command)
    }
    let command = try #require(registry.command(for: chord), "nothing is bound to \(chord)")
    let binding = try #require(TilingCommands.bindings.first { $0.command == command })
    var closed: CloseResult?
    binding.run(
        CommandContext(
            pane: workspace.selectedTab.focusedPane.commandPane, workspace: workspace,
            tabBounds: { bounds }, didClosePane: { closed = $0 }))
    return closed
}

private func arrow(_ direction: Direction) -> KeyChord.Key {
    switch direction {
    case .left: .left
    case .right: .right
    case .up: .up
    case .down: .down
    }
}

private func focusKey(_ direction: Direction) -> KeyChord {
    KeyChord(arrow(direction), modifiers: [.command, .option, .shift])
}

private func moveKey(_ direction: Direction) -> KeyChord {
    KeyChord(arrow(direction), modifiers: [.control, .option, .shift])
}

private func resizeKey(_ direction: Direction) -> KeyChord {
    KeyChord(arrow(direction), modifiers: [.control, .command])
}

private let splitRight = KeyChord("\\", modifiers: .command)
private let splitDown = KeyChord("\\", modifiers: [.command, .shift])
private let zoom = KeyChord("z", modifiers: [.command, .option, .shift])
private let equalize = KeyChord("0", modifiers: [.command, .option])
private let closePane = KeyChord("w", modifiers: .command)

private func expectClose(_ a: Rect?, _ b: Rect?, sourceLocation: SourceLocation = #_sourceLocation)
{
    guard let a, let b else {
        Issue.record("missing frame", sourceLocation: sourceLocation)
        return
    }
    #expect(abs(a.x - b.x) < tolerance, sourceLocation: sourceLocation)
    #expect(abs(a.y - b.y) < tolerance, sourceLocation: sourceLocation)
    #expect(abs(a.width - b.width) < tolerance, sourceLocation: sourceLocation)
    #expect(abs(a.height - b.height) < tolerance, sourceLocation: sourceLocation)
}

// MARK: Chords

@Test func eachTilingChordInTheKeyTableResolvesToItsCommand() throws {
    var registry = CommandRegistry()
    for binding in TilingCommands.bindings {
        try registry.register(binding.command)
    }
    var expected: [(KeyChord, Command)] = [
        (splitRight, TilingCommands.splitRight),
        (splitDown, TilingCommands.splitDown),
        (zoom, TilingCommands.zoom),
        (equalize, TilingCommands.equalize),
        (closePane, TilingCommands.closePane),
    ]
    for direction in Direction.allCases {
        expected.append((focusKey(direction), try #require(TilingCommands.focus[direction])))
        expected.append((moveKey(direction), try #require(TilingCommands.move[direction])))
        expected.append((resizeKey(direction), try #require(TilingCommands.resize[direction])))
    }

    for (chord, command) in expected {
        #expect(registry.command(for: chord) == command, "\(chord)")
    }
    #expect(TilingCommands.bindings.count == expected.count)
}

@Test func cmdOptArrowsAreUnbound() throws {
    let registry = try AppCommands.registry()
    for direction in Direction.allCases {
        let chord = KeyChord(arrow(direction), modifiers: [.command, .option])
        #expect(registry.command(for: chord) == nil, "\(chord)")
    }
}

@Test func zoomIsOnCmdOptShiftZAndNotOnCmdShiftReturn() throws {
    let registry = try AppCommands.registry()
    let old = KeyChord(.return, modifiers: [.command, .shift])
    #expect(registry.command(for: old) == nil, "\(old)")
    #expect(registry.command(for: zoom)?.id == TilingCommands.zoom.id)
    let redo = KeyChord("z", modifiers: [.command, .shift])
    #expect(registry.command(for: redo) == nil, "\(redo)")
}

@Test func resizeStepIsFortyPoints() {
    #expect(TilingCommands.resizeStep == 40)
}

// MARK: The 2×2 grid

@MainActor @Test func splitRightAndDownSplitTheFocusedPaneAndFocusTheNewOne() throws {
    let grid = try Grid()
    let before = grid.frames

    try press(splitRight, in: grid.workspace)
    let right = grid.tab.layout.focused
    let afterRight = grid.frames

    #expect(grid.tab.layout.panes.count == 5)
    #expect(grid.tab.panes.count == 5)
    #expect(![grid.a, grid.b, grid.c, grid.d].contains(right))
    let d = try #require(before[grid.d])
    let half = (d.width - Layout.dividerThickness) / 2
    expectClose(afterRight[grid.d], Rect(x: d.x, y: d.y, width: half, height: d.height))
    expectClose(
        afterRight[right],
        Rect(x: d.x + half + Layout.dividerThickness, y: d.y, width: half, height: d.height))
    expectClose(afterRight[grid.a], before[grid.a])

    try press(splitDown, in: grid.workspace)
    let below = grid.tab.layout.focused
    let r = try #require(afterRight[right])
    let halfHeight = (r.height - Layout.dividerThickness) / 2

    #expect(grid.tab.layout.panes.count == 6)
    expectClose(grid.frames[right], Rect(x: r.x, y: r.y, width: r.width, height: halfHeight))
    expectClose(
        grid.frames[below],
        Rect(
            x: r.x, y: r.y + halfHeight + Layout.dividerThickness, width: r.width,
            height: halfHeight))
}

@MainActor @Test func focusKeysMoveTheFocusToTheNeighborInThatDirection() throws {
    let grid = try Grid()

    try press(focusKey(.left), in: grid.workspace)
    #expect(grid.tab.layout.focused == grid.c)
    try press(focusKey(.up), in: grid.workspace)
    #expect(grid.tab.layout.focused == grid.a)
    try press(focusKey(.right), in: grid.workspace)
    #expect(grid.tab.layout.focused == grid.b)
    try press(focusKey(.down), in: grid.workspace)
    #expect(grid.tab.layout.focused == grid.d)
    // Nothing lies right of D.
    try press(focusKey(.right), in: grid.workspace)
    #expect(grid.tab.layout.focused == grid.d)
}

@MainActor @Test func moveKeysSwapTheFocusedPaneWithItsNeighborAndKeepFocusOnIt() throws {
    let grid = try Grid()
    let before = grid.frames

    try press(moveKey(.left), in: grid.workspace)

    #expect(grid.tab.layout.focused == grid.d)
    expectClose(grid.frames[grid.d], before[grid.c])
    expectClose(grid.frames[grid.c], before[grid.d])

    try press(moveKey(.up), in: grid.workspace)

    expectClose(grid.frames[grid.d], before[grid.a])
    expectClose(grid.frames[grid.a], before[grid.c])
    expectClose(grid.frames[grid.b], before[grid.b])
}

@MainActor @Test func zoomKeyTogglesZoomOnTheFocusedPane() throws {
    let grid = try Grid()

    try press(zoom, in: grid.workspace)
    #expect(grid.tab.layout.isZoomed)
    #expect(grid.frames == [grid.d: bounds])

    try press(zoom, in: grid.workspace)
    #expect(!grid.tab.layout.isZoomed)
    #expect(grid.frames.count == 4)
}

@MainActor @Test func equalizeKeyGivesEveryPaneTheSameSize() throws {
    let grid = try Grid()
    try press(resizeKey(.left), in: grid.workspace)
    try press(resizeKey(.up), in: grid.workspace)

    try press(equalize, in: grid.workspace)

    let frames = grid.frames
    let a = try #require(frames[grid.a])
    for pane in [grid.b, grid.c, grid.d] {
        let frame = try #require(frames[pane])
        #expect(abs(frame.width - a.width) < tolerance)
        #expect(abs(frame.height - a.height) < tolerance)
    }
}

// MARK: Resize

@MainActor @Test func resizeMovesTheNearestSplitInThatDirectionByTheStep() throws {
    let grid = try Grid()
    let before = grid.frames

    // D sits in the right column, so the split nearest it across ← is the one between the
    // columns.
    try press(resizeKey(.left), in: grid.workspace)

    var frames = grid.frames
    for pane in [grid.a, grid.c] {
        let old = try #require(before[pane])
        #expect(abs(try #require(frames[pane]).width - (old.width - 40)) < tolerance)
    }
    for pane in [grid.b, grid.d] {
        let old = try #require(before[pane])
        #expect(abs(try #require(frames[pane]).width - (old.width + 40)) < tolerance)
    }

    // Across ↑ the nearest split is the one inside the right column, between B and D. The left
    // column's split stays.
    try press(resizeKey(.up), in: grid.workspace)

    frames = grid.frames
    let b = try #require(before[grid.b])
    let d = try #require(before[grid.d])
    #expect(abs(try #require(frames[grid.b]).height - (b.height - 40)) < tolerance)
    #expect(abs(try #require(frames[grid.d]).height - (d.height + 40)) < tolerance)
    #expect(frames[grid.a]?.height == before[grid.a]?.height)

    try press(resizeKey(.right), in: grid.workspace)
    try press(resizeKey(.down), in: grid.workspace)

    for pane in [grid.a, grid.b, grid.c, grid.d] {
        expectClose(grid.frames[pane], before[pane])
    }
}

@MainActor @Test func resizeStopsAtTheMinimumPaneSize() throws {
    let grid = try Grid()

    // 1200 pt wide: each column starts near 600 pt, so 13 steps of 40 pt would pass 120 pt.
    for _ in 0..<20 {
        try press(resizeKey(.left), in: grid.workspace)
    }
    for _ in 0..<20 {
        try press(resizeKey(.up), in: grid.workspace)
    }

    let frames = grid.frames
    #expect(abs(try #require(frames[grid.a]).width - Layout.minimumPaneSize) < tolerance)
    #expect(abs(try #require(frames[grid.c]).width - Layout.minimumPaneSize) < tolerance)
    #expect(abs(try #require(frames[grid.b]).height - Layout.minimumPaneSize) < tolerance)
}

/// Three panes in a row along `axis`, p0 first. With `nestedSecond` the tree is p0 | (p1 | p2);
/// otherwise (p0 | p1) | p2. Both look the same on screen.
@MainActor
private func threePanes(along axis: Axis, nestedSecond: Bool) throws -> (Workspace, [PaneID]) {
    let workspace = oneTabWorkspace()
    let tab = workspace.selectedTab
    let p0 = tab.layout.focused
    if nestedSecond {
        try #require(tab.split(axis, in: bounds) != nil)
        let p1 = tab.layout.focused
        try #require(tab.split(axis, in: bounds) != nil)
        return (workspace, [p0, p1, tab.layout.focused])
    }
    try #require(tab.split(axis, in: bounds) != nil)
    let p2 = tab.layout.focused
    tab.focus(p0)
    try #require(tab.split(axis, in: bounds) != nil)
    return (workspace, [p0, tab.layout.focused, p2])
}

/// Where the two dividers between three panes in a row along `axis` sit.
@MainActor
private func dividerPositions(_ tab: Tab, _ panes: [PaneID], along axis: Axis) throws -> [Double] {
    let frames = tab.layout.frames(in: bounds)
    return try panes.prefix(2).map { pane in
        let frame = try #require(frames[pane])
        return axis == .horizontal ? frame.maxX : frame.maxY
    }
}

@MainActor @Test(arguments: [Axis.horizontal, .vertical], [true, false])
func resizeMovesTheDividerOnTheTrailingEdgeElseTheLeadingOne(axis: Axis, nestedSecond: Bool)
    throws
{
    let (workspace, panes) = try threePanes(along: axis, nestedSecond: nestedSecond)
    let tab = workspace.selectedTab
    let (back, forward): (Direction, Direction) =
        axis == .horizontal ? (.left, .right) : (.up, .down)
    // p0 and p1 move the divider on their right or bottom edge; p2 has none there, so it moves
    // the one on its left or top edge.
    let moved = [0, 1, 1]

    for (index, pane) in panes.enumerated() {
        for (direction, sign) in [(back, -1.0), (forward, 1.0)] {
            tab.equalize(in: bounds)
            tab.focus(pane)
            let before = try dividerPositions(tab, panes, along: axis)

            try press(resizeKey(direction), in: workspace)

            // Only the moved divider is checked: a nested split keeps its ratio, so its divider
            // shifts with its parent's.
            let divider = moved[index]
            let after = try dividerPositions(tab, panes, along: axis)
            #expect(
                abs(after[divider] - (before[divider] + sign * TilingCommands.resizeStep))
                    < tolerance, "p\(index) \(direction)")
        }
    }
}

@MainActor @Test func resizeAcrossTheOtherAxisChangesNothing() throws {
    let (workspace, panes) = try threePanes(along: .horizontal, nestedSecond: true)
    let tab = workspace.selectedTab
    let before = tab.layout.frames(in: bounds)

    for pane in panes {
        tab.focus(pane)
        try press(resizeKey(.up), in: workspace)
        try press(resizeKey(.down), in: workspace)
    }

    #expect(tab.layout.frames(in: bounds) == before)
}

// MARK: Context

@MainActor @Test func contextTrapsWhenItsPaneIsNotTheSelectedTabsFocusedPane() async {
    await #expect(processExitsWith: .failure) {
        await MainActor.run {
            let workspace = oneTabWorkspace()
            let other = PaneFixture(at: "/r", folders: ["/r": []], held: true).pane
            _ = CommandContext(pane: other, workspace: workspace)
        }
    }
}

@MainActor @Test func paneOnlyContextTrapsWhenAskedForItsWorkspace() async {
    await #expect(processExitsWith: .failure) {
        await MainActor.run {
            let pane = PaneFixture(at: "/r", folders: ["/r": []], held: true).pane
            _ = CommandContext(pane: pane).workspace
        }
    }
}

// MARK: Zoom

@MainActor @Test func whileZoomedSplitFocusAndMoveUnzoomFirst() throws {
    let grid = try Grid()
    let edgeKeys = [focusKey(.right), moveKey(.down)]

    // D has no neighbor to the right or below, so only unzooming changes the layout.
    for key in edgeKeys {
        try press(zoom, in: grid.workspace)
        try #require(grid.tab.layout.isZoomed)

        try press(key, in: grid.workspace)

        #expect(!grid.tab.layout.isZoomed, "\(key)")
        #expect(grid.tab.layout.focused == grid.d, "\(key)")
    }

    try press(zoom, in: grid.workspace)
    try press(focusKey(.left), in: grid.workspace)
    #expect(!grid.tab.layout.isZoomed)
    #expect(grid.tab.layout.focused == grid.c)

    try press(zoom, in: grid.workspace)
    try press(moveKey(.up), in: grid.workspace)
    #expect(!grid.tab.layout.isZoomed)

    try press(zoom, in: grid.workspace)
    try press(splitRight, in: grid.workspace)
    #expect(!grid.tab.layout.isZoomed)
    #expect(grid.tab.layout.panes.count == 5)
}

@MainActor @Test func whileZoomedARefusedSplitStillUnzooms() throws {
    let workspace = oneTabWorkspace()
    let tab = workspace.selectedTab
    // Splitting right until a split is refused leaves the focused pane under twice the minimum.
    while tab.split(.horizontal, in: bounds) != nil {}
    try press(zoom, in: workspace)
    let panes = tab.panes.count

    try press(splitRight, in: workspace)

    #expect(tab.panes.count == panes)
    #expect(!tab.layout.isZoomed)
}

// MARK: Close

@MainActor @Test func closeKeyClosesTheFocusedPaneAndReportsIt() throws {
    let grid = try Grid()
    let closing = grid.tab.panes[grid.d]
    try press(focusKey(.up), in: grid.workspace)
    try press(focusKey(.down), in: grid.workspace)

    let result = try press(closePane, in: grid.workspace)

    #expect(result == .pane)
    #expect(Set(grid.tab.layout.panes) == [grid.a, grid.b, grid.c])
    #expect(grid.tab.layout.focused == grid.b)
    #expect(closing?.load?.isCancelled == true)
}

@MainActor @Test func closeKeyOnALastPaneReportsTheTabAndLeavesTheWindowToTheCaller() throws {
    let workspace = oneTabWorkspace()
    let first = workspace.selectedTab
    let second = Tab(pane: PaneFixture(at: "/r", folders: ["/r": []], held: true).pane)
    workspace.add(second)

    #expect(try press(closePane, in: workspace) == .tab)
    #expect(workspace.tabs.map(\.id) == [first.id])
    #expect(workspace.selectedTab === first)

    #expect(try press(closePane, in: workspace) == .workspace)
    // The workspace keeps its closed tab; Interface closes the window.
    #expect(workspace.tabs.map(\.id) == [first.id])
}
