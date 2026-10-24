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
    case .splits:
        record.splitDown = try at("B6", 500)
        record.gridDown = try at("B6", 500)
        record.tenPaneOpen = try at("B2.W2", 20)
    case .restoredSession:
        record.launch = try at("B1", UIBenchReport.launches)
    case .restoredNetworkPane:
        record.restoredCachedRows = try at("B4", UIBenchReport.launches)
    case .palette:
        record.paletteKey = try at("B11", UIBenchReport.paletteKeys)
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
    #expect(
        budgets == [
            ["B6", "B6", "B6"], ["B3"], ["B4"], ["B6"], ["B6", "B6", "B2.W2"], ["B1"], ["B4"],
            ["B11"],
        ])
}

@Test func restoredSessionTimesEachLaunchToTheRestoredWindows() throws {
    let report = try UIBenchReport(
        record: try samples(for: .restoredSession, atFraction: 0.5), scenario: .restoredSession)
    #expect(
        report.cases.map(\.name) == [
            "launch → restored windows, key window's focused pane rows frame"
        ])
    #expect(report.cases[0].samples.count == UIBenchReport.launches)
}

@Test func restoredSessionRunsOnW1AndW2WithoutAPath() throws {
    #expect(
        try BenchArguments.parse(["--ui", "/b/Searcher.app", "--scenario", "restored-session"])
            == .ui(app: "/b/Searcher.app", folder: nil, scenario: .restoredSession))
    #expect(UIBenchReport.keyPresses(launch: 0, scenario: .restoredSession) == 0)
}

@Test func restoredNetworkPaneTimesEachLaunchToTheCachedRows() throws {
    let report = try UIBenchReport(
        record: try samples(for: .restoredNetworkPane, atFraction: 0.5),
        scenario: .restoredNetworkPane)
    #expect(report.cases.map(\.name) == ["restored window shown → cached rows frame"])
    #expect(report.cases[0].samples.count == UIBenchReport.launches)
    #expect(UIBenchReport.launches(for: .restoredNetworkPane) == UIBenchReport.launches)
    #expect(UIBenchReport.keyPresses(launch: 0, scenario: .restoredNetworkPane) == 0)
}

@Test func restoredNetworkPaneParsesWithItsPath() throws {
    let folder = FileManager.default.temporaryDirectory.path
    #expect(
        try BenchArguments.parse(
            ["--ui", "/b/Searcher.app", "--scenario", "restored-network-pane", "--path", folder])
            == .ui(app: "/b/Searcher.app", folder: folder, scenario: .restoredNetworkPane))
    let options = UIBenchOptions(
        output: "/o.json", w1: folder, w2: folder, keyPresses: 0, tempPrefix: "p",
        scenario: .restoredNetworkPane, folders: [])
    #expect(UIBenchOptions(arguments: ["Searcher"] + options.arguments) == options)
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

@Test(arguments: [
    Scenario.columnKeys, .cold, .revisit, .splits, .restoredSession, .restoredNetworkPane, .palette,
])
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
            == "unknown scenario warm; the scenarios are column-keys, cold, revisit, column-walk, "
            + "splits, restored-session, restored-network-pane, palette"
    }
}

@Test func scenarioNeedsAName() {
    #expect {
        try BenchArguments.parse(["--ui", "/b/Searcher.app", "--scenario"])
    } throws: { error in
        String(describing: error).contains(
            "column-keys, cold, revisit, column-walk, splits, restored-session, restored-network-pane, "
                + "palette")
    }
}

@Test func scenarioNeedsTheUI() {
    #expect {
        try BenchArguments.parse(["--scenario", "column-keys"])
    } throws: { error in
        String(describing: error).contains("--ui")
    }
}

@Test(arguments: [Scenario.cold, .revisit, .columnWalk, .restoredNetworkPane])
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

/// A restored session gives one B1 sample per launch, and a restored network pane one B4
/// sample, so they launch as often as the CI run.
@Test func scenarioRunsOneLaunchAndKeepsItsOwnRecord() {
    #expect(UIBenchReport.launches(for: nil) == UIBenchReport.launches)
    #expect(UIBenchReport.launches(for: .restoredSession) == UIBenchReport.launches)
    for scenario in Scenario.allCases {
        if scenario != .restoredSession && scenario != .restoredNetworkPane {
            #expect(UIBenchReport.launches(for: scenario) == 1)
        }
        #expect(UIBenchReport.path(for: scenario) != UIBenchReport.path)
    }
}

@Test func splitsRunsOnW2WithoutAPath() throws {
    #expect(
        try BenchArguments.parse(["--ui", "/b/Searcher.app", "--scenario", "splits"])
            == .ui(app: "/b/Searcher.app", folder: nil, scenario: .splits))
}

@Test func keysArePressedInTheFirstLaunchOfTheCIRunAndTheW2Scenarios() {
    #expect(UIBenchReport.keyPresses(launch: 0, scenario: nil) == UIBenchReport.keyPresses)
    #expect(UIBenchReport.keyPresses(launch: 1, scenario: nil) == 0)
    #expect(UIBenchReport.keyPresses(launch: 0, scenario: .columnKeys) == UIBenchReport.keyPresses)
    #expect(UIBenchReport.keyPresses(launch: 0, scenario: .splits) == UIBenchReport.keyPresses)
    #expect(UIBenchReport.keyPresses(launch: 0, scenario: .cold) == 0)
}

@Test func paletteTimesEachKeyToItsFrameWithoutAPath() throws {
    #expect(
        try BenchArguments.parse(["--ui", "/b/Searcher.app", "--scenario", "palette"])
            == .ui(app: "/b/Searcher.app", folder: nil, scenario: .palette))
    let options = UIBenchOptions(
        output: "/o.json", w1: "/w1", w2: "/w2", keyPresses: 0, tempPrefix: "p",
        scenario: .palette, folders: [])
    #expect(UIBenchOptions(arguments: ["Searcher"] + options.arguments) == options)
    let report = try UIBenchReport(
        record: try samples(for: .palette, atFraction: 0.5), scenario: .palette)
    #expect(
        report.cases.map(\.name) == [
            "palette keystroke → frame, \(UIBenchOptions.paletteCandidates) candidates"
        ])
    #expect(report.cases[0].budget?.id == "B11")
    #expect(UIBenchReport.launches(for: .palette) == 1)
    #expect(UIBenchReport.keyPresses(launch: 0, scenario: .palette) == 0)
    #expect(UIBenchOptions.paletteCandidates == 50_000)
}
