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
