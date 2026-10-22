import Foundation

/// The processes using the most CPU while the runner starts, recorded with every run so a slow
/// number can be traced to a busy machine. This type holds the only copy of the busy rule.
struct MachineLoad: Sendable, Codable {
    struct TopProcess: Sendable, Codable, Equatable {
        let pid: Int32
        /// As `top` prints it, cut to 16 characters.
        let command: String
        /// Percent of one core, so a multithreaded process can be over 100.
        let cpu: Double
    }

    /// Another process over this percent of one core makes the machine busy.
    static let busyPercent = 50.0
    static let sampleSeconds = 1
    static let recordedCount = 5

    /// Highest CPU first, at most `recordedCount`.
    let topProcesses: [TopProcess]

    init(topProcesses: [TopProcess]) {
        self.topProcesses = topProcesses
    }

    /// Reads the last sample of `top -l 2 -o cpu -stats pid,cpu,command` output, leaving out
    /// `pids`. The first sample's CPU column isn't a rate yet, which is why `top` takes two.
    init(top output: String, excluding pids: Set<Int32>) throws {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let header = lines.lastIndex(where: { $0.hasPrefix("PID") }) else {
            throw Unreadable(output: output)
        }
        var processes: [TopProcess] = []
        for line in lines[(header + 1)...] where !line.allSatisfy(\.isWhitespace) {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let cpu = Double(fields[1])
            else { throw Unreadable(output: output) }
            if pids.contains(pid) { continue }
            processes.append(
                TopProcess(
                    pid: pid, command: fields[2].trimmingCharacters(in: .whitespaces), cpu: cpu))
        }
        topProcesses = Array(processes.sorted { $0.cpu > $1.cpu }.prefix(Self.recordedCount))
    }

    /// Samples the machine for `sampleSeconds`, leaving out this process and `top` itself. Blocks
    /// for the sample, so call it off the main thread.
    static func sample() throws -> MachineLoad {
        let top = Process()
        top.executableURL = URL(filePath: "/usr/bin/top")
        // Two more rows than recorded, for this process and `top`.
        top.arguments = [
            "-l", "2", "-s", String(sampleSeconds), "-n", String(recordedCount + 2), "-o", "cpu",
            "-stats", "pid,cpu,command",
        ]
        let pipe = Pipe()
        top.standardOutput = pipe
        try top.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        top.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard top.terminationStatus == 0 else { throw Unreadable(output: output) }
        return try MachineLoad(
            top: output,
            excluding: [ProcessInfo.processInfo.processIdentifier, top.processIdentifier]
        )
    }

    var busy: [TopProcess] { topProcesses.filter { $0.cpu > Self.busyPercent } }

    /// Names every busy process, or nil when the machine is idle.
    var warning: String? {
        guard !busy.isEmpty else { return nil }
        let names = busy.map { "\($0.command) (pid \($0.pid)) at \($0.cpu)% CPU" }
        return "machine busy: \(names.joined(separator: ", ")); timings may be slow"
    }

    private enum CodingKeys: String, CodingKey {
        case topProcesses, busy
    }

    /// `busy` is derived from `topProcesses`, so it is written for readers and not read back.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        topProcesses = try container.decode([TopProcess].self, forKey: .topProcesses)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(topProcesses, forKey: .topProcesses)
        try container.encode(busy, forKey: .busy)
    }

    struct Unreadable: Error, CustomStringConvertible {
        let output: String
        var description: String { "could not read top's output:\n\(output)" }
    }
}
