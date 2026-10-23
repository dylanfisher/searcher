import Base
import Testing

@testable import Bench

@Test func overBudgetFailsTheRun() throws {
    let report = BenchReport(
        machine: MachineLoad(topProcesses: []),
        cases: [
            BenchReport.Case(
                name: "slow", budget: try Budget.named("B10"), unit: .milliseconds,
                samples: Samples([10, 20, 60]))
        ])
    #expect(!report.passed)
    #expect(report.overBudget.map(\.name) == ["slow"])
}

@Test func underBudgetPasses() throws {
    let report = BenchReport(
        machine: MachineLoad(topProcesses: []),
        cases: [
            BenchReport.Case(
                name: "fast", budget: try Budget.named("B10"), unit: .milliseconds,
                samples: Samples([10, 20, 49])),
            BenchReport.Case(
                name: "unbudgeted", budget: nil, unit: .milliseconds, samples: Samples([900])),
        ])
    #expect(report.passed)
}

@Test func noCasesPasses() {
    #expect(BenchReport(machine: MachineLoad(topProcesses: []), cases: []).passed)
}

/// One run of a copy case per sample, each the milliseconds its 1 GB took, off CI unless
/// `environment` says otherwise.
private func copyReport(
    _ milliseconds: [Double], environment: [String: String] = [:]
) -> BenchReport {
    BenchReport(
        machine: MachineLoad(topProcesses: []),
        cases: [
            BenchReport.Case(
                name: "copy", budget: nil, floor: .s7, unit: .milliseconds,
                samples: Samples(milliseconds), environment: environment)
        ])
}

@Test func copySlowerThanS7FailsTheRun() {
    // 1 GB in 2 s is 500 MB/s, under S7's floor, at the p95.
    let report = copyReport([1000, 1000, 2000])
    #expect(!report.passed)
    #expect(report.overBudget.map(\.name) == ["copy"])
}

@Test func copyFasterThanS7Passes() {
    // 1 GB in 1 s is 1000 MB/s.
    #expect(copyReport([900, 1000, 1000]).passed)
}

@Test func copyCaseIsPrintedInMegabytesPerSecondAgainstS7() {
    let text = line(for: copyReport([1000, 1000, 2000]).cases[0])
    #expect(text.contains("median 1000.00 MB/s"), "\(text)")
    #expect(text.contains("p95 500.00 MB/s"), "\(text)")
    #expect(text.contains("floor S7 \(CopyFloor.s7.megabytesPerSecond) MB/s"), "\(text)")
    #expect(text.contains("OVER BUDGET"), "\(text)")
}

@Test func copySlowerThanS7OnCIIsReportedAndPasses() {
    let report = copyReport([1000, 1000, 2000], environment: ["CI": "true"])
    #expect(report.passed)
    let text = line(for: report.cases[0])
    #expect(text.contains("p95 500.00 MB/s"), "\(text)")
    #expect(
        text.contains("floor S7 \(CopyFloor.s7.megabytesPerSecond) MB/s, reported only on CI"),
        "\(text)")
    #expect(text.contains("UNDER FLOOR (reported only)"), "\(text)")
    #expect(!text.contains("OVER BUDGET"), "\(text)")
}

@Test func copyFasterThanS7OnCIIsNotMarked() {
    let text = line(for: copyReport([900, 1000, 1000], environment: ["CI": "true"]).cases[0])
    #expect(!text.contains("UNDER FLOOR"), "\(text)")
}
