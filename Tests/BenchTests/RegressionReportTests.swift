import Base
import Foundation
import Testing

@testable import Bench

private func report(_ cases: [BenchReport.Case]) -> BenchReport {
    BenchReport(machine: MachineLoad(topProcesses: []), cases: cases)
}

private func timed(_ name: String, budget: String? = nil, median: Double) throws
    -> BenchReport.Case
{
    BenchReport.Case(
        name: name, budget: try budget.map(Budget.named), unit: .milliseconds,
        samples: Samples([median]))
}

@Test func caseFifteenPercentSlowerWithinBudgetIsReportedAndPasses() throws {
    let previous = report([try timed("open", budget: "B10", median: 20)])
    let current = report([try timed("open", budget: "B10", median: 23)])
    let regression = RegressionReport(previous: previous, current: current)
    #expect(regression.slower.map(\.name) == ["open"])
    #expect(regression.text.contains("open"))
    #expect(regression.text.contains("15.0%"))
    #expect(regression.passed)
}

@Test func caseWithinTenPercentIsNotReported() throws {
    let previous = report([try timed("open", median: 20)])
    let current = report([try timed("open", median: 22)])
    let regression = RegressionReport(previous: previous, current: current)
    #expect(regression.slower.isEmpty)
}

@Test func slowdownIsJudgedOnTheMedianNotTheP95() {
    func steady(_ samples: [Double]) -> BenchReport {
        report([
            BenchReport.Case(
                name: "idle", budget: nil, unit: .milliseconds, samples: Samples(samples))
        ])
    }
    // One slow run doubles the p95 and leaves the median where it was.
    let regression = RegressionReport(
        previous: steady([20, 20, 20, 20, 20]), current: steady([20, 20, 20, 20, 40]))
    #expect(regression.slower.isEmpty)
}

@Test func caseOverBudgetFails() throws {
    let previous = report([try timed("open", budget: "B10", median: 20)])
    let current = report([try timed("open", budget: "B10", median: 60)])
    let regression = RegressionReport(previous: previous, current: current)
    #expect(!regression.passed)
    #expect(regression.text.contains("over budget"))
}

@Test func missingPreviousReportIsStated() throws {
    let current = report([try timed("open", median: 20)])
    let regression = RegressionReport(previous: nil, current: current)
    #expect(regression.text.contains("no previous report"))
    #expect(regression.slower.isEmpty)
    #expect(regression.passed)
}

@Test func newAndRemovedCasesAreStatedNotFailed() throws {
    let previous = report([try timed("old", median: 20)])
    let current = report([try timed("new", median: 20)])
    let regression = RegressionReport(previous: previous, current: current)
    #expect(regression.text.contains("new case: new"))
    #expect(regression.text.contains("not in this run: old"))
    #expect(regression.passed)
}

@Test func casesWithDifferentUnitsAreNotCompared() throws {
    let previous = report([try timed("open", median: 20)])
    let current = report([
        BenchReport.Case(name: "open", budget: nil, unit: .megabytes, samples: Samples([40]))
    ])
    let regression = RegressionReport(previous: previous, current: current)
    #expect(regression.slower.isEmpty)
    #expect(regression.text.contains("unit changed: open"))
}

@Test func reportRoundTripsThroughJSON() throws {
    let original = report([try timed("open", budget: "B10", median: 20)])
    let path = FileManager.default.temporaryDirectory
        .appending(path: "searcher-bench-\(UUID().uuidString).json").path
    try original.write(to: path)
    defer { try? FileManager.default.removeItem(atPath: path) }
    let loaded = try BenchReport.read(from: path)
    #expect(loaded.cases.map(\.name) == ["open"])
    #expect(loaded.cases[0].median == 20)
}

@Test func compareArgumentsNameBothReports() throws {
    #expect(
        try BenchArguments.parse(["compare", "a.json", "b.json"])
            == .compare(previous: "a.json", current: "b.json"))
}

@Test func compareWithoutTwoPathsFails() {
    #expect(throws: BenchArguments.Invalid.self) {
        try BenchArguments.parse(["compare", "a.json"])
    }
}

/// One complete UI bench run: every span the same in each launch, and ↓ at `keyDown` ms, which is
/// then its p95. B6 is 16 ms.
private func uiRun(keyDown: Double, launches: Int = UIBenchReport.launches) -> UIBenchRecord {
    UIBenchRecord(
        launch: Array(repeating: 200, count: launches),
        openW1: Array(repeating: 10, count: launches),
        openW2: Array(repeating: 30, count: launches),
        keyDown: Array(repeating: keyDown, count: UIBenchReport.keyPresses),
        optionArrows: Array(repeating: 5, count: 200),
        controlShiftDown: Array(repeating: 5, count: 200),
        pageDown: Array(repeating: 5, count: 200), shiftDown: Array(repeating: 5, count: 200),
        selectAll: Array(repeating: 5, count: 100),
        patchAllSelected: Array(repeating: 5, count: 100),
        reloadAllSelected: Array(repeating: 5, count: 20),
        patchAddingAllSelected: Array(repeating: 5, count: 100),
        clickHalf: Array(repeating: 5, count: 100),
        patchAfterShiftDown: Array(repeating: 5, count: 100),
        loadAfterSelectAll: Array(repeating: 5, count: 20),
        typeSelect: Array(repeating: 5, count: 24),
        sortChange: Array(repeating: 90, count: launches),
        hiddenToggle: Array(repeating: 40, count: 2 * launches),
        foldersFirstToggle: Array(repeating: 40, count: 2 * launches),
        sortKey: Array(repeating: 60, count: 2 * launches),
        filterKey: Array(repeating: 20, count: 6 * launches))
}

/// Judges one CI run per ↓ p95 in order, each against the history the one before it kept, and
/// returns the last run's report.
private func judgeUI(
    _ keyDowns: [Double], branch: String = "m0", from start: RegressionReport.UIHistory? = nil
)
    throws -> RegressionReport.UI
{
    var history = start
    var last: RegressionReport.UI?
    for keyDown in keyDowns {
        let run = try RegressionReport.UI(
            previous: history, current: uiRun(keyDown: keyDown), branch: branch)
        history = run.history
        last = run
    }
    return try #require(last)
}

private let keyDownCase = "W2 ↓ key → frame"

private func keyDownEnforced(_ report: RegressionReport.UI) -> Bool? {
    report.history.cases.first { $0.name == keyDownCase }?.enforced
}

@Test func uiCaseOverBudgetIsReportedNotFailedWhileReportOnly() throws {
    let report = try judgeUI([30])
    #expect(report.passed)
    #expect(keyDownEnforced(report) == false)
    #expect(report.text.contains("over budget (report-only): \(keyDownCase)"), "\(report.text)")
}

@Test func threeUIRunsWithinTenPercentEnforceTheCaseThenOverBudgetFails() throws {
    let third = try judgeUI([10, 10.5, 10.9])
    #expect(third.passed)
    #expect(keyDownEnforced(third) == true)
    #expect(
        third.text.contains("p95 10.90 ms  budget B6 16 ms  enforced from this run"),
        "\(third.text)")

    let fourth = try judgeUI([10, 10.5, 10.9, 30])
    #expect(!fourth.passed)
    #expect(fourth.text.contains("over budget: \(keyDownCase) p95 30.00 ms"), "\(fourth.text)")
}

@Test func anEnforcedUICaseStaysEnforcedAfterAnUnsteadyRun() throws {
    let report = try judgeUI([10, 10, 10, 14, 10])
    #expect(keyDownEnforced(report) == true)
    #expect(report.passed)
}

@Test func twoUIRunsWithinTenPercentAndOneAtFifteenStayReportOnly() throws {
    // All three are over B6, so a case that had been enforced would fail.
    let report = try judgeUI([20, 20.5, 23])
    #expect(keyDownEnforced(report) == false)
    #expect(report.passed)
    #expect(report.text.contains("report-only"), "\(report.text)")
    #expect(report.text.contains("over budget (report-only): \(keyDownCase)"), "\(report.text)")
}

@Test func uiHistoryFromAnotherBranchKeepsEnforcementAndCountsRunsAgain() throws {
    let main = try judgeUI([10, 10, 10], branch: "main").history
    let report = try judgeUI([10], branch: "feature", from: main)
    #expect(keyDownEnforced(report) == true)
    #expect(report.history.branch == "feature")
    #expect(report.history.cases.allSatisfy { $0.p95s.count == 1 })
    #expect(report.text.contains("from branch main"), "\(report.text)")

    // A case not yet enforced on main starts its count again on the new branch.
    let unsteady = try judgeUI([10, 10], branch: "main").history
    let restarted = try judgeUI([10, 10], branch: "feature", from: unsteady)
    #expect(keyDownEnforced(restarted) == false)
}

@Test func missingUIHistoryIsStated() throws {
    let report = try judgeUI([10])
    #expect(report.text.contains("no previous UI history"), "\(report.text)")
}

@Test func uiRunThatDidNotFinishIsAnError() {
    #expect {
        try RegressionReport.UI(
            previous: nil, current: uiRun(keyDown: 10, launches: 3), branch: "m0")
    } throws: { error in
        String(describing: error).contains("3 of \(UIBenchReport.launches)")
            && String(describing: error).contains("did not finish")
    }
}

@Test func uiRecordWithMoreLaunchesThanOneRunIsAnError() {
    let launches = UIBenchReport.launches + 1
    #expect {
        try RegressionReport.UI(
            previous: nil, current: uiRun(keyDown: 10, launches: launches), branch: "m0")
    } throws: { error in
        let text = String(describing: error)
        return text.contains("\(launches) launches") && !text.contains("did not finish")
    }
}

@Test func unreadableUIHistoryIsStatedAndDiscarded() throws {
    let report = try RegressionReport.UI(
        previous: nil, unreadablePrevious: "bad JSON", current: uiRun(keyDown: 10), branch: "m0")
    #expect(
        report.text.contains("previous UI history unreadable: bad JSON, discarded"),
        "\(report.text)")
    #expect(!report.text.contains("no previous UI history"), "\(report.text)")
}

@Test func uiHistoryRoundTripsThroughJSON() throws {
    let original = try judgeUI([10, 11]).history
    let path = FileManager.default.temporaryDirectory
        .appending(path: "searcher-bench-ui-history-\(UUID().uuidString).json").path
    try original.write(to: path)
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(try RegressionReport.UIHistory.read(from: path) == original)
}

@Test func compareUIArgumentsNameBothFilesAndTheBranch() throws {
    #expect(
        try BenchArguments.parse(["compare-ui", "history.json", "bench-ui.json", "main"])
            == .compareUI(previous: "history.json", current: "bench-ui.json", branch: "main"))
}

@Test func compareUIWithoutTheBranchFails() {
    #expect(throws: BenchArguments.Invalid.self) {
        try BenchArguments.parse(["compare-ui", "history.json", "bench-ui.json"])
    }
}
