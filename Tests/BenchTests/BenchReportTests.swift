import Base
import Testing

@testable import Bench

@Test func overBudgetFailsTheRun() throws {
    let report = BenchReport(
        machine: MachineLoad(topProcesses: []),
        cases: [
            BenchReport.Case(
                name: "slow", budget: try Budget.named("B10"), samples: Samples([10, 20, 60]))
        ])
    #expect(!report.passed)
    #expect(report.overBudget.map(\.name) == ["slow"])
}

@Test func underBudgetPasses() throws {
    let report = BenchReport(
        machine: MachineLoad(topProcesses: []),
        cases: [
            BenchReport.Case(
                name: "fast", budget: try Budget.named("B10"), samples: Samples([10, 20, 49])),
            BenchReport.Case(name: "unbudgeted", budget: nil, samples: Samples([900])),
        ])
    #expect(report.passed)
}

@Test func noCasesPasses() {
    #expect(BenchReport(machine: MachineLoad(topProcesses: []), cases: []).passed)
}
