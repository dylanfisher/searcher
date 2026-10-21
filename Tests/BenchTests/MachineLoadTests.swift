import Foundation
import Testing

@testable import Bench

/// Two samples as `top -l 2 -s 1 -o cpu -stats pid,cpu,command` prints them. The first sample's
/// CPU column is not a rate yet, so only the second counts.
private func topOutput(lastSample rows: String) -> String {
    """
    Processes: 814 total, 3 running, 2 stuck, 809 sleeping, 4435 threads
    2026/10/20 22:47:49
    CPU usage: 24.17% user, 10.19% sys, 65.62% idle

    PID    %CPU COMMAND
    99948  95.0 zsh
    99947  0.0  login
    Processes: 814 total, 2 running, 1 stuck, 811 sleeping, 4456 threads
    2026/10/20 22:47:50
    CPU usage: 20.88% user, 6.65% sys, 72.46% idle

    PID    %CPU  COMMAND
    \(rows)
    """
}

@Test func processOver50PercentIsBusyAndNamed() throws {
    let load = try MachineLoad(
        top: topOutput(
            lastSample: """
                26462  80.0  Google Chrome He
                0      24.4  kernel_task
                171    15.2  WindowServer
                """),
        excluding: [])
    #expect(load.busy.map(\.command) == ["Google Chrome He"])
    #expect(load.busy.map(\.pid) == [26462])
    #expect(load.warning?.contains("Google Chrome He") == true)
}

@Test func busyMeansOver50Percent() throws {
    let load = try MachineLoad(
        top: topOutput(
            lastSample: """
                300    50.1  over
                200    50.0  at
                """),
        excluding: [])
    #expect(load.busy.map(\.command) == ["over"])
}

@Test func quietSampleIsIdle() throws {
    let load = try MachineLoad(
        top: topOutput(
            lastSample: """
                0      24.4  kernel_task
                171    15.2  WindowServer
                """),
        excluding: [])
    #expect(load.busy.isEmpty)
    #expect(load.warning == nil)
    #expect(load.topProcesses.map(\.cpu) == [24.4, 15.2])
}

@Test func excludedProcessesDoNotCount() throws {
    let load = try MachineLoad(
        top: topOutput(
            lastSample: """
                61906  90.0  top
                500    70.0  Bench
                171    15.2  WindowServer
                """),
        excluding: [61906, 500])
    #expect(load.busy.isEmpty)
    #expect(load.topProcesses.map(\.pid) == [171])
}

@Test func keepsTheTopFive() throws {
    let rows = (1...7).map { "\($0)  \(8 - $0).0  p\($0)" }.joined(separator: "\n")
    let load = try MachineLoad(top: topOutput(lastSample: rows), excluding: [])
    #expect(load.topProcesses.map(\.command) == ["p1", "p2", "p3", "p4", "p5"])
}

@Test func outputWithoutSampleFails() {
    #expect(throws: MachineLoad.Unreadable.self) {
        try MachineLoad(top: "top: failed\n", excluding: [])
    }
}

@Test func reportListsTopProcesses() throws {
    let load = try MachineLoad(
        top: topOutput(lastSample: "26462  80.0  Google Chrome He"), excluding: [])
    let json = try JSONSerialization.jsonObject(
        with: try JSONEncoder().encode(BenchReport(machine: load, cases: [])))
    let machine = try #require((json as? [String: Any])?["machine"] as? [String: Any])
    let top = try #require(machine["topProcesses"] as? [[String: Any]])
    #expect(top.first?["command"] as? String == "Google Chrome He")
    let busy = try #require(machine["busy"] as? [[String: Any]])
    #expect(busy.count == 1)
}
