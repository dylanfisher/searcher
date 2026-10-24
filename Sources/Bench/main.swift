import Base
import Foundation

/// Builds any missing fixture, samples the machine, times every registered case and the copy case
/// to the disk image mounted at `image`, prints median and p95 for each, writes the report, and
/// returns whether every budgeted p95 is within its budget. A busy machine is warned about and
/// recorded, not a failure.
func runCases(folder: String?, image: String?) async throws -> Bool {
    guard let image else { throw ImageMissing(run: "the harness's copy case") }
    try prepareFixtures()
    try prepare(Fixture(.copySource))
    let machine = try MachineLoad.sample()
    if let warning = machine.warning { printError(warning) }
    var results: [BenchReport.Case] = []
    for benchCase in BenchCase.registered + [BenchCase.copy(to: image)] {
        let result = BenchReport.Case(
            name: benchCase.name, budget: benchCase.budget, floor: benchCase.floor,
            unit: benchCase.unit, samples: try await benchCase.measure(folder: folder))
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

/// Judges the UI bench record at `current` against the history at `previous`, writes the next
/// history to `RegressionReport.UIHistory.path`, and prints the result. A previous history that is
/// missing or can't be read is stated and discarded. A record that is missing or doesn't hold one
/// run's launches is printed, no history is written, and the run fails. Returns whether no enforced
/// case is over budget.
func runCompareUI(previous: String, current: String, branch: String) throws -> Bool {
    guard FileManager.default.fileExists(atPath: current) else {
        print(
            "the UI bench did not finish: \(current) does not exist; its error is in the bench's output"
        )
        return false
    }
    let record = try UIBenchRecord.decode(Data(contentsOf: URL(filePath: current)))
    var before: RegressionReport.UIHistory?
    var unreadable: String?
    if FileManager.default.fileExists(atPath: previous) {
        do {
            before = try RegressionReport.UIHistory.read(from: previous)
        } catch {
            unreadable = "\(previous): \(error)"
        }
    } else {
        printError("previous UI history \(previous) does not exist")
    }
    // On standard output, which CI puts in the step summary.
    let report: RegressionReport.UI
    do {
        report = try RegressionReport.UI(
            previous: before, unreadablePrevious: unreadable, current: record, branch: branch)
    } catch let error as RegressionReport.UI.Incomplete {
        print(error.description)
        return false
    } catch let error as RegressionReport.UI.TooManyLaunches {
        print(error.description)
        return false
    }
    try report.history.write(to: RegressionReport.UIHistory.path)
    print(report.text)
    return report.passed
}

/// Launches the app bundle at `app` in its UI bench mode `UIBenchReport.launches(for:)` times,
/// each a new process, so every launch is a cold launch (B1) with a warm file-system cache. The
/// first launch also presses ↓ `UIBenchReport.keyPresses` times, in the list, while the queue
/// copies `w8` to the disk image mounted at `image`, in column view and in two split layouts.
/// A scenario is one launch that times only its own spans, on `folder` when it needs a real one.
/// Each launch writes its samples to `UIBenchReport.path(for:)`; the runner reads them after it
/// exits and writes all of them back there. Returns whether every span is within budget, and for
/// `column-walk` whether no stall came after the launch; other runs report stalls only.
func runUI(
    app: String, folder: String?, scenario: UIBenchOptions.Scenario?, image: String?,
    w8 workload: Fixture.Workload
) throws -> Bool {
    if scenario == nil, image == nil { throw ImageMissing(run: "the UI bench's W8 copy") }
    if scenario?.needsPath != true { try prepareFixtures() }
    let w8 = Fixture(workload)
    if scenario == nil { try prepare(w8) }
    let machine = try MachineLoad.sample()
    if let warning = machine.warning { printError(warning) }
    guard let executable = Bundle(path: app)?.executableURL else {
        throw UILaunchFailed(description: "\(app) is not an app bundle")
    }
    let recordPath = UIBenchReport.path(for: scenario)
    let output = URL(filePath: FileManager.default.currentDirectoryPath)
        .appending(path: recordPath)
    let stallArguments = try BenchArguments.stallArguments()
    // Listed here, before the app starts, so the app opens each one for the first time.
    var folders: [String] = []
    if scenario == .cold || scenario == .revisit, let folder {
        folders = try ColdChildren.children(of: folder, lister: DirectoryLister())
    }
    // One prefix per run, so a launch that had to be stopped can be cleaned up after.
    let tempPrefix = "searcher-bench-ui-\(ProcessInfo.processInfo.processIdentifier)"
    var record = UIBenchRecord()
    for launch in 0..<UIBenchReport.launches(for: scenario) {
        let options = UIBenchOptions(
            output: output.path, w1: folder ?? Fixture(.w1).path.path,
            w2: folder ?? Fixture(.w2).path.path,
            keyPresses: UIBenchReport.keyPresses(launch: launch, scenario: scenario),
            tempPrefix: tempPrefix,
            scenario: scenario, folders: folders,
            w8: scenario == nil ? w8.path.path : nil, image: scenario == nil ? image : nil)
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
    print("wrote \(recordPath)")
    let report = try UIBenchReport(record: record, scenario: scenario)
    print(report.text)
    for miss in report.overBudget {
        let budget = miss.budget.map(describe) ?? "none"
        printError(
            "over budget: \(miss.name) p95 \(format(miss.p95)) \(miss.unit.rawValue), budget \(budget)"
        )
    }
    if let budget = report.stallBudget, !report.stallsOverBudget.isEmpty {
        printError(
            "over budget: \(report.stallsOverBudget.count) stalls after launch, budget \(describe(budget))"
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

struct ImageMissing: Error, CustomStringConvertible {
    let run: String
    var description: String {
        "\(run) needs --image <mount point> of an attached disk image; scripts/bench makes one"
    }
}

/// Checks the free space `run` needs before anything is written and prints what scripts/bench
/// reads: the disk image's size in MB and the folder to make it in, or 0 when `run` copies
/// nothing. Throws, naming the bytes, when the space is short.
func printDiskImageSize(for run: BenchArguments) throws {
    guard let plan = DiskImagePlan(for: run) else {
        print("0")
        return
    }
    let folder = FileManager.default.temporaryDirectory.path
    try plan.check(free: try DiskImagePlan.freeBytes(in: folder), in: folder)
    print("\(plan.imageMegabytes) \(folder)")
}

func line(for result: BenchReport.Case) -> String {
    let unit = result.unit.rawValue
    var line =
        "\(result.name)  median \(format(result.median)) \(unit)  p95 \(format(result.p95)) \(unit)"
    if let budget = result.budget { line += "  budget \(describe(budget))" }
    if let floor = result.floor {
        // The p95 time is the slow end, so it gives the low rate; the median rate is the one judged.
        line +=
            "  median \(format(floor.rate(milliseconds: result.median))) MB/s"
            + "  p95 \(format(floor.rate(milliseconds: result.p95))) MB/s  \(result.limit)"
    }
    if result.overBudget { line += "  OVER BUDGET" }
    if result.underFloorReportedOnly { line += "  UNDER FLOOR (reported only)" }
    return line
}

/// Writes the report, names each miss, and returns whether every case is within its budget or floor.
func finish(_ report: BenchReport) throws -> Bool {
    try report.write(to: BenchReport.path)
    print("wrote \(BenchReport.path)")
    for miss in report.overBudget {
        printError(miss.missText())
    }
    return report.passed
}

/// Builds any missing listing workload.
func prepareFixtures() throws {
    for workload in Fixture.Workload.listing {
        try prepare(Fixture(workload))
    }
}

func prepare(_ fixture: Fixture) throws {
    var built = false
    let elapsed = try ContinuousClock().measure { built = try fixture.prepare() }
    print(built ? "built \(fixture.path.path) in \(elapsed)" : "reusing \(fixture.path.path)")
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
        case .run(let folder, let image):
            exit(try await runCases(folder: folder, image: image) ? 0 : 1)
        case .diskImageSize(let run):
            try printDiskImageSize(for: run)
            exit(0)
        case .compareUI(let previous, let current, let branch):
            exit(try runCompareUI(previous: previous, current: current, branch: branch) ? 0 : 1)
        case .ui(let app, let folder, let scenario, let image, let w8):
            exit(
                try runUI(app: app, folder: folder, scenario: scenario, image: image, w8: w8)
                    ? 0 : 1)
        case .help:
            print(BenchArguments.scenarioHelp)
            exit(0)
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
