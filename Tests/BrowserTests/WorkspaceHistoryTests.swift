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

/// A step keeps its panes' own Back past nothing: 500 entries each way stay 500.
@Test func aStepKeepsItsPanesHistoriesAtTheirLimitThroughARoundTrip() throws {
    let entries = (0...History.limit).map { "/\($0)" }
    var history = WorkspaceHistory()
    history.leave(step("/a", back: entries))

    let decoded = try JSONDecoder().decode(
        WorkspaceHistory.self, from: JSONEncoder().encode(history))

    #expect(decoded == history)
    let pane = try #require(decoded.back.first?.tabs.first?.panes.values.first)
    #expect(pane.history.backEntries.count == History.limit)
    #expect(pane.history.backEntries.first?.location == Location(path: "/1"))
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
