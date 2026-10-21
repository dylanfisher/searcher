import Base
import Foundation

/// Builds any missing fixture, samples the machine, times every registered case, prints median and
/// p95 for each, writes the report, and returns whether every budgeted p95 is within its budget.
/// A busy machine is warned about and recorded, not a failure.
func runCases(folder: String?) async throws -> Bool {
    try prepareFixtures()
    let machine = try MachineLoad.sample()
    if let warning = machine.warning { printError(warning) }
    if BenchCase.registered.isEmpty { print("no cases registered") }
    var results: [BenchReport.Case] = []
    for benchCase in BenchCase.registered {
        let result = BenchReport.Case(
            name: benchCase.name, budget: benchCase.budget, unit: benchCase.unit,
            samples: try await benchCase.measure(folder: folder))
        print(line(for: result))
        results.append(result)
    }
    return try finish(BenchReport(machine: machine, cases: results))
}

/// Times 20 different subfolders of `folder` once each and reports them against B3. The report
/// name says the runs were cold, as docs/performance.md asks.
func runColdChildren(folder: String) throws -> Bool {
    let machine = try MachineLoad.sample()
    if let warning = machine.warning { printError(warning) }
    let samples = try ColdChildren.time(in: folder, lister: DirectoryLister())
    let result = BenchReport.Case(
        name: "cold children of \(folder): list each once", budget: try Budget.named("B3"),
        unit: .milliseconds, samples: samples)
    print(line(for: result))
    return try finish(BenchReport(machine: machine, cases: [result]))
}

func line(for result: BenchReport.Case) -> String {
    let unit = result.unit.rawValue
    var line =
        "\(result.name)  median \(format(result.median)) \(unit)  p95 \(format(result.p95)) \(unit)"
    if let budget = result.budget { line += "  budget \(describe(budget))" }
    if result.overBudget { line += "  OVER BUDGET" }
    return line
}

/// Writes the report, names each miss, and returns whether every budgeted p95 is within budget.
func finish(_ report: BenchReport) throws -> Bool {
    try report.write(to: BenchReport.path)
    print("wrote \(BenchReport.path)")
    for miss in report.overBudget {
        // Only budgeted cases can be over budget, so `budget` is never nil here.
        let budget = miss.budget.map(describe) ?? "none"
        printError(
            "over budget: \(miss.name) p95 \(format(miss.p95)) \(miss.unit.rawValue), budget \(budget)"
        )
    }
    return report.passed
}

func prepareFixtures() throws {
    let clock = ContinuousClock()
    for workload in Fixture.Workload.allCases {
        let fixture = Fixture(workload)
        var built = false
        let elapsed = try clock.measure { built = try fixture.prepare() }
        print(built ? "built \(fixture.path.path) in \(elapsed)" : "reusing \(fixture.path.path)")
    }
}

/// Prints the top processes and returns false, naming each busy one, when the machine is busy.
func checkIdle() throws -> Bool {
    let machine = try MachineLoad.sample()
    for process in machine.topProcesses {
        print("\(process.pid)  \(process.cpu)%  \(process.command)")
    }
    guard let warning = machine.warning else {
        print("idle")
        return true
    }
    printError(warning)
    return false
}

func describe(_ budget: Budget) -> String {
    "\(budget.id) \(budget.limit) \(budget.unit.rawValue)"
}

func format(_ value: Double) -> String {
    String(format: "%.2f", value)
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data("bench: \(message)\n".utf8))
}

// Cases list and stat folders, so the runner stays off the main thread.
Task.detached {
    do {
        switch try BenchArguments.parse(Array(CommandLine.arguments.dropFirst())) {
        case .printBudget(let budget):
            print(budget.formattedLimit)
            exit(0)
        case .checkIdle:
            exit(try checkIdle() ? 0 : 1)
        case .footprintOfOpening(let folder):
            print(try await BenchCase.footprintOfOpening(folder))
            exit(0)
        case .coldChildren(let folder):
            exit(try runColdChildren(folder: folder) ? 0 : 1)
        case .run(let folder):
            exit(try await runCases(folder: folder) ? 0 : 1)
        }
    } catch {
        printError("\(error)")
        exit(1)
    }
}
// ListingService hands updates to the main actor on the main queue. `dispatchMain` would park the
// main thread and run that queue on another thread, where the main actor's isolation check traps;
// the run loop runs it on the main thread, as the app's does.
CFRunLoopRun()
