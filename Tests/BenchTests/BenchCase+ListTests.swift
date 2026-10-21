import Foundation
import TestSupport
import Testing

@testable import Bench

@Test func listCasesAreReportedWithoutBudgets() {
    let names = BenchCase.list.map(\.name)
    for workload in ["W1", "W2", "W5"] {
        #expect(names.contains("list \(workload): first batch"))
        #expect(names.contains("list \(workload): full"))
    }
    #expect(names.contains("sort W2: key build"))
    #expect(names.contains("sort W2: listing build (keys, kinds, name order)"))
    #expect(names.contains("sort W2: by size"))
    #expect(BenchCase.list.allSatisfy { $0.budget == nil && $0.unit == .milliseconds })
}

@Test func listCasesRunOnAFolder() async throws {
    let folder = try TemporaryFolder("BenchCaseListTests")
    // More entries than one getattrlistbulk buffer holds, so there is a first batch before the end.
    for index in 0..<2_500 {
        try Data().write(to: folder.url.appending(path: "file-\(index)"))
    }
    for benchCase in BenchCase.list {
        #expect(try await benchCase.run(folder.url.path) > 0, "\(benchCase.name)")
    }
}

@Test func idleWatchdogCaseRunsAndIsReported() async throws {
    #expect(
        BenchCase.idle.map(\.name)
            == ["idle 5 s: CPU without the watchdog", "idle 5 s: CPU with the watchdog running"])
    #expect(BenchCase.idle.allSatisfy { $0.runs == 5 })
    #expect(BenchCase.idle.allSatisfy { $0.budget == nil && $0.unit == .milliseconds })
    let cpu = try await BenchCase.idleCPU(with: .milliseconds(300), watchdog: true)
    #expect(try await BenchCase.idleCPU(with: .milliseconds(100), watchdog: false) >= 0)
    // Other tests run in the same process, so only the bench run itself bounds the number.
    #expect(cpu >= 0)
}
