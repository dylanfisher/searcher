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

/// Prints what changed between two saved reports. A previous report that is missing or can't be
/// read is stated and the comparison is skipped; an unreadable current report is an error.
/// Returns whether the current report has no case over budget.
func runCompare(previous: String, current: String) throws -> Bool {
    let now = try BenchReport.read(from: current)
    var before: BenchReport?
    if FileManager.default.fileExists(atPath: previous) {
        do {
            before = try BenchReport.read(from: previous)
        } catch {
            printError("previous report \(previous) is unreadable: \(error)")
        }
    } else {
        printError("previous report \(previous) does not exist")
    }
    let regression = RegressionReport(previous: before, current: now)
    print(regression.text)
    return regression.passed
}

/// Launches the app bundle at `app` in its UI bench mode `UIBenchReport.launches` times, each a
/// new process, so every launch is a cold launch (B1) with a warm file-system cache. The first
/// launch also presses ↓ `UIBenchReport.keyPresses` times. Each launch writes its samples to
/// `UIBenchReport.path`; the runner reads them after it exits and writes all of them back there.
/// Returns whether every span is within budget; stalls are reported only.
func runUI(app: String, folder: String?) throws -> Bool {
    try prepareFixtures()
    let machine = try MachineLoad.sample()
    if let warning = machine.warning { printError(warning) }
    guard let executable = Bundle(path: app)?.executableURL else {
        throw UILaunchFailed(description: "\(app) is not an app bundle")
    }
    let output = URL(filePath: FileManager.default.currentDirectoryPath)
        .appending(path: UIBenchReport.path)
    let stallArguments = try BenchArguments.stallArguments()
    // One prefix per run, so a launch that had to be stopped can be cleaned up after.
    let tempPrefix = "searcher-bench-ui-\(ProcessInfo.processInfo.processIdentifier)"
    var record = UIBenchRecord()
    for launch in 0..<UIBenchReport.launches {
        let options = UIBenchOptions(
            output: output.path, w1: folder ?? Fixture(.w1).path.path,
            w2: folder ?? Fixture(.w2).path.path,
            keyPresses: launch == 0 ? UIBenchReport.keyPresses : 0, tempPrefix: tempPrefix)
        // A launch that fails before writing must not leave the last one's samples to be read.
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        do {
            try launchOnce(
                executable, arguments: options.arguments + stallArguments, number: launch + 1)
        } catch {
            // A launch cleans up after itself, even on SIGTERM; one killed harder can't.
            try TempRoot.removeAll(prefix: tempPrefix)
            throw error
        }
        record.append(try UIBenchRecord.decode(Data(contentsOf: output)))
    }
    try AtomicWrite.write(try record.encoded(), to: output)
    print("wrote \(UIBenchReport.path)")
    let report = try UIBenchReport(record: record)
    print(report.text)
    for miss in report.overBudget {
        let budget = miss.budget.map(describe) ?? "none"
        printError(
            "over budget: \(miss.name) p95 \(format(miss.p95)) \(miss.unit.rawValue), budget \(budget)"
        )
    }
    return report.passed
}

/// Runs the app's executable directly rather than through `open`, so a copy of the app that is
/// already running, which has the same bundle ID, is left alone and not brought to the front,
/// and the app's exit status and error output reach the runner.
private func launchOnce(_ executable: URL, arguments: [String], number: Int) throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
    if exited.wait(timeout: .now() + .seconds(UIBenchReport.launchTimeout)) == .timedOut {
        // SIGTERM lets the app remove its temporary folder; one that doesn't exit is killed.
        process.terminate()
        if exited.wait(timeout: .now() + .seconds(5)) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            exited.wait()
        }
        throw UILaunchFailed(
            description:
                "UI bench launch \(number) did not finish within \(UIBenchReport.launchTimeout) s")
    }
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw UILaunchFailed(
            description:
                "UI bench launch \(number) ended with status \(process.terminationStatus); its message is above"
        )
    }
}

struct UILaunchFailed: Error, CustomStringConvertible {
    let description: String
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
        case .printStallArguments:
            print(try BenchArguments.stallArguments().joined(separator: " "))
            exit(0)
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
        case .compare(let previous, let current):
            exit(try runCompare(previous: previous, current: current) ? 0 : 1)
        case .run(let folder):
            exit(try await runCases(folder: folder) ? 0 : 1)
        case .ui(let app, let folder):
            exit(try runUI(app: app, folder: folder) ? 0 : 1)
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
