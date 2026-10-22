import Base
import Foundation
import Testing

@testable import Bench

typealias Scenario = UIBenchOptions.Scenario

/// A record holding only `scenario`'s spans, each sample at `fraction` of its budget, and a
/// launch, which every launch records.
private func samples(for scenario: Scenario, atFraction fraction: Double) throws -> UIBenchRecord {
    func at(_ id: String, _ count: Int) throws -> [Double] {
        Array(repeating: Double(try Budget.named(id).limit) * fraction, count: count)
    }
    var record = UIBenchRecord(launch: [200])
    switch scenario {
    case .columnKeys:
        record.columnDown = try at("B6", 500)
        record.columnRight = try at("B6", 100)
        record.columnLeft = try at("B6", 100)
    case .cold:
        record.coldOpen = try at("B3", 20)
    case .revisit:
        record.revisit = try at("B4", 20)
    case .columnWalk:
        record.columnWalkKey = try at("B6", 120)
    }
    return record
}

@Test(arguments: Scenario.allCases)
func scenarioUnderBudgetPasses(_ scenario: Scenario) throws {
    let report = try UIBenchReport(
        record: try samples(for: scenario, atFraction: 0.5), scenario: scenario)
    #expect(report.passed, "\(report.text)")
    #expect(!report.cases.isEmpty)
}

@Test(arguments: Scenario.allCases)
func scenarioOverBudgetFailsNamingEachCase(_ scenario: Scenario) throws {
    let report = try UIBenchReport(
        record: try samples(for: scenario, atFraction: 2), scenario: scenario)
    #expect(!report.passed)
    #expect(report.overBudget.map(\.name) == report.cases.map(\.name))
}

@Test func scenarioBudgetsAreTheirBudgets() throws {
    let budgets = try Scenario.allCases.map { scenario in
        try UIBenchReport(record: try samples(for: scenario, atFraction: 0.5), scenario: scenario)
            .cases.compactMap { $0.budget?.id }
    }
    #expect(budgets == [["B6", "B6", "B6"], ["B3"], ["B4"], ["B6"]])
}

@Test func scenarioReportsOnlyItsOwnSpans() throws {
    // A cold run records no ↓ presses on W2, and that is not an error.
    let report = try UIBenchReport(
        record: try samples(for: .cold, atFraction: 0.5), scenario: .cold)
    #expect(report.cases.map(\.name) == ["cold open of a subfolder → first rows frame"])
}

@Test func scenarioWithNoSamplesIsAnError() {
    #expect {
        try UIBenchReport(record: UIBenchRecord(launch: [200]), scenario: .revisit)
    } throws: { error in
        String(describing: error).contains("revisit")
    }
}

@Test func columnWalkFailsOnAStallOutsideTheLaunch() throws {
    var record = try samples(for: .columnWalk, atFraction: 0.5)
    record.stalls = [UIBenchRecord.Stall(milliseconds: 60, span: "column walk key")]
    let report = try UIBenchReport(record: record, scenario: .columnWalk)
    #expect(!report.passed)
    #expect(
        report.text.contains("stalls: 1, longest 60.00 ms (B10 50 ms)  OVER BUDGET"),
        "\(report.text)")
}

@Test func columnWalkPassesWithAStallInTheLaunchOnly() throws {
    var record = try samples(for: .columnWalk, atFraction: 0.5)
    record.stalls = [UIBenchRecord.Stall(milliseconds: 60, span: "\(UIBenchRecord.launchSpan)")]
    let report = try UIBenchReport(record: record, scenario: .columnWalk)
    #expect(report.passed, "\(report.text)")
}

@Test func columnWalkPassesWithAStallInTheLaunchWarmUp() throws {
    var record = try samples(for: .columnWalk, atFraction: 0.5)
    record.stalls = [UIBenchRecord.Stall(milliseconds: 80, span: UIBenchRecord.warmUpSpan)]
    let report = try UIBenchReport(record: record, scenario: .columnWalk)
    #expect(report.passed, "\(report.text)")
}

@Test func columnWalkFailsOnAStallBetweenSpansAfterTheWarmUp() throws {
    var record = try samples(for: .columnWalk, atFraction: 0.5)
    record.stalls = [
        UIBenchRecord.Stall(milliseconds: 80, span: UIBenchRecord.warmUpSpan),
        UIBenchRecord.Stall(milliseconds: 60, span: UIBenchRecord.betweenSpans),
    ]
    let report = try UIBenchReport(record: record, scenario: .columnWalk)
    #expect(report.stallsOverBudget.map(\.span) == [UIBenchRecord.betweenSpans])
    #expect(!report.passed)
}

@Test(arguments: [Scenario.columnKeys, .cold, .revisit])
func otherScenariosReportStallsOnly(_ scenario: Scenario) throws {
    var record = try samples(for: scenario, atFraction: 0.5)
    record.stalls = [UIBenchRecord.Stall(milliseconds: 60, span: "between spans")]
    let report = try UIBenchReport(record: record, scenario: scenario)
    #expect(report.passed)
    #expect(report.text.contains("(B10, reported only)"), "\(report.text)")
}

// MARK: Arguments

@Test func unknownScenarioFailsListingTheNames() {
    #expect {
        try BenchArguments.parse(["--ui", "/b/Searcher.app", "--scenario", "warm"])
    } throws: { error in
        String(describing: error)
            == "unknown scenario warm; the scenarios are column-keys, cold, revisit, column-walk"
    }
}

@Test func scenarioNeedsAName() {
    #expect {
        try BenchArguments.parse(["--ui", "/b/Searcher.app", "--scenario"])
    } throws: { error in
        String(describing: error).contains("column-keys, cold, revisit, column-walk")
    }
}

@Test func scenarioNeedsTheUI() {
    #expect {
        try BenchArguments.parse(["--scenario", "column-keys"])
    } throws: { error in
        String(describing: error).contains("--ui")
    }
}

@Test(arguments: [Scenario.cold, .revisit, .columnWalk])
func pathScenarioWithoutAPathFails(_ scenario: Scenario) {
    #expect {
        try BenchArguments.parse(["--ui", "/b/Searcher.app", "--scenario", scenario.rawValue])
    } throws: { error in
        String(describing: error).contains("\(scenario.rawValue) needs --path")
    }
}

@Test func pathScenarioKeepsThePath() throws {
    let folder = FileManager.default.temporaryDirectory.path
    #expect(
        try BenchArguments.parse(
            ["--ui", "/b/Searcher.app", "--scenario", "cold", "--path", folder])
            == .ui(app: "/b/Searcher.app", folder: folder, scenario: .cold))
}

@Test func columnKeysRunsOnW2WithoutAPath() throws {
    #expect(
        try BenchArguments.parse(["--ui", "/b/Searcher.app", "--scenario", "column-keys"])
            == .ui(app: "/b/Searcher.app", folder: nil, scenario: .columnKeys))
}

@Test func helpListsEveryScenario() throws {
    #expect(try BenchArguments.parse(["--help"]) == .help)
    for scenario in Scenario.allCases {
        #expect(
            BenchArguments.scenarioHelp.contains(scenario.rawValue),
            "\(BenchArguments.scenarioHelp)")
    }
}

@Test func scenarioRunsOneLaunchAndKeepsItsOwnRecord() {
    #expect(UIBenchReport.launches(for: nil) == UIBenchReport.launches)
    for scenario in Scenario.allCases {
        #expect(UIBenchReport.launches(for: scenario) == 1)
        #expect(UIBenchReport.path(for: scenario) != UIBenchReport.path)
    }
}
