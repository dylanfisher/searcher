import Foundation
import Testing

@testable import Browser

/// The one layout of every step, so steps of the same folder are equal.
private let layout = Layout()

/// A step of one tab of one pane at `path`, with `back` as the pane's Back entries.
private func step(_ path: String, back: [String] = []) -> WorkspaceHistory.Step {
    WorkspaceHistory.Step(
        tabs: [
            TabState(
                layout: layout,
                panes: [
                    layout.focused: TabState.PaneState(
                        location: Location(path: path), viewMode: .list,
                        history: History(
                            back: back.map {
                                History.Entry(location: Location(path: $0), selected: nil)
                            }, forward: []),
                        selection: [], cursor: nil, sortColumn: .name, sortAscending: true,
                        columnWidths: ColumnWidths())
                ])
        ], selectedTab: 0, showsSidebar: false)
}

@Test func backStepsToWhatTheWindowLeftAndForwardReturns() {
    var history = WorkspaceHistory()
    history.leave(step("/a"))

    #expect(history.back(from: step("/b")) == step("/a"))
    #expect(history.back.isEmpty)
    #expect(history.forward(from: step("/a")) == step("/b"))
    #expect(history.forward.isEmpty)
    #expect(history.back == [step("/a")])
}

@Test func leavingOrDroppingForwardEndsTheWayForward() {
    var history = WorkspaceHistory()
    history.leave(step("/a"))
    _ = history.back(from: step("/b"))
    history.leave(step("/c"))
    #expect(history.forward.isEmpty)

    _ = history.back(from: step("/d"))
    #expect(!history.forward.isEmpty)
    history.dropForward()

    #expect(history.forward.isEmpty)
    #expect(history.back.isEmpty)
}

@Test func eachWayKeepsItsNearestStepsUpToTheLimit() {
    var history = WorkspaceHistory()
    for index in 0...WorkspaceHistory.limit {
        history.leave(step("/\(index)"))
    }

    #expect(history.back.count == WorkspaceHistory.limit)
    #expect(history.back.first == step("/1"))
    #expect(history.back.last == step("/\(WorkspaceHistory.limit)"))
    let long = (0...WorkspaceHistory.limit).map { step("/\($0)") }
    #expect(WorkspaceHistory(back: long, forward: long).forward == Array(long.dropFirst()))
}

/// A step keeps each pane's nearest `paneEntries` each way, whichever way it was added; the
/// live pane's own Back keeps its 500 (`History.limit`).
@Test func aStepKeepsEachPanesNearestEntriesThroughARoundTrip() throws {
    let entries = (0...History.limit).map { "/\($0)" }
    let full = step("/a", back: entries)
    #expect(full.tabs[0].panes.values.first?.history.backEntries.count == History.limit)
    var history = WorkspaceHistory()
    history.leave(full)
    _ = history.back(from: full)

    let decoded = try JSONDecoder().decode(
        WorkspaceHistory.self, from: JSONEncoder().encode(history))

    #expect(decoded == history)
    for kept in decoded.forward + WorkspaceHistory(back: [full], forward: []).back {
        let pane = try #require(kept.tabs.first?.panes.values.first)
        #expect(
            pane.history.backEntries.map(\.location)
                == entries.suffix(WorkspaceHistory.paneEntries).map { Location(path: $0) })
    }
}

/// `value` as a JSON object.
private func object(_ value: some Encodable) throws -> [String: Any] {
    try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
}

/// Stored steps past the limit either way, a step's pane past its entries, or a history of
/// another shape is rejected, not trimmed: the file holding it is discarded.
@Test func storedStepsPastTheirBoundsOrOfAnotherShapeAreRejected() throws {
    let one = try object(WorkspaceHistory(back: [step("/a")], forward: []))
    let stepJSON = try object(step("/a"))
    let longPane = try object(
        step("/a", back: (0...WorkspaceHistory.paneEntries).map { "/\($0)" }))
    var tooMany = one
    tooMany["back"] = Array(repeating: stepJSON, count: WorkspaceHistory.limit + 1)
    var tooLong = one
    tooLong["forward"] = [longPane]
    var missing = one
    missing["forward"] = nil
    var wrongType = one
    wrongType["back"] = "steps"

    for broken in [tooMany, tooLong, missing, wrongType] {
        let data = try JSONSerialization.data(withJSONObject: broken)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(WorkspaceHistory.self, from: data)
        }
    }
    var atLimit = one
    atLimit["back"] = Array(repeating: stepJSON, count: WorkspaceHistory.limit)
    let data = try JSONSerialization.data(withJSONObject: atLimit)
    #expect(
        try JSONDecoder().decode(WorkspaceHistory.self, from: data).back.count
            == WorkspaceHistory.limit)
}

/// The window file of the largest window the step bounds are set for: 8 tabs of a 2 × 2 grid,
/// every pane at a 100-character path with 500 entries of Back and Forward of its own, and 10
/// steps each way of the same tabs, in `WorkspaceStore`'s format: sorted keys.
@Test func aWindowFileWithTheMostStepsStaysUnderAMegabyte() throws {
    let deep = "/Users/someone/Documents/Projects/" + String(repeating: "a", count: 66)
    let entries = (0..<History.limit).map {
        History.Entry(location: Location(path: deep), selected: ExactName("item \($0).txt"))
    }
    let tabs = try (0..<8).map { _ in
        var layout = Layout()
        let grid = layout.makeGrid(
            columns: 2, rows: 2, in: Rect(x: 0, y: 0, width: 1600, height: 1000))
        _ = try #require(grid)
        return TabState(
            layout: layout,
            panes: Dictionary(
                uniqueKeysWithValues: layout.panes.map { id in
                    (
                        id,
                        TabState.PaneState(
                            location: Location(path: deep), viewMode: .column,
                            history: History(back: entries, forward: entries),
                            selection: [ExactName("item 1.txt")],
                            cursor: ExactName("item 1.txt"), sortColumn: .name,
                            sortAscending: true, columnWidths: ColumnWidths())
                    )
                }))
    }
    let shown = WorkspaceHistory.Step(tabs: tabs, selectedTab: 0, showsSidebar: true)
    let steps = Array(repeating: shown, count: WorkspaceHistory.limit)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let window = WorkspaceState(
        id: UUID(), name: nil, frame: Rect(x: 0, y: 0, width: 1600, height: 1000), tabs: tabs,
        selectedTab: 0, showsSidebar: true, history: WorkspaceHistory())

    let bare = try encoder.encode(window).count
    let full = try encoder.encode(
        window.withHistory(WorkspaceHistory(back: steps, forward: steps))
    ).count

    print("WS.1 window file: \(bare) bytes without steps, \(full) with 20")
    #expect(full - bare < 1_000_000)
}

@Test func aStoredStepWithItsSelectedTabOutOfRangeIsRejected() throws {
    let json = try JSONEncoder().encode(step("/a"))
    var object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
    object["selectedTab"] = 3
    let broken = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(WorkspaceHistory.Step.self, from: broken)
    }
}
