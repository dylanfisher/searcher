import Base
import Testing

@testable import Bench

/// A record with every span under its budget and no stalls; tests change one span.
private func underBudget() -> UIBenchRecord {
    UIBenchRecord(
        launch: [200, 210], openW1: [10, 12], openW2: [30, 40],
        keyDown: Array(repeating: 4, count: 500), sortChange: [90, 100], stalls: [])
}

@Test func keyDownUnderB6Passes() throws {
    let report = try UIBenchReport(record: underBudget())
    #expect(report.passed)
    #expect(report.cases.first { $0.budget?.id == "B6" }?.samples.count == 500)
}

@Test func keyDownOverB6FailsNamingIt() throws {
    var record = underBudget()
    // 30 of 500 over 16 ms puts the p95 over.
    record.keyDown = Array(repeating: 4, count: 470) + Array(repeating: 25, count: 30)
    let report = try UIBenchReport(record: record)
    #expect(!report.passed)
    #expect(report.overBudget.map { $0.budget?.id } == ["B6"])
}

@Test func stallsAreReportedWithTheirSpanAndDontFail() throws {
    var record = underBudget()
    record.stalls = [
        UIBenchRecord.Stall(milliseconds: 55, span: "launch"),
        UIBenchRecord.Stall(milliseconds: 72, span: "open W2"),
    ]
    let report = try UIBenchReport(record: record)
    #expect(report.passed)
    #expect(report.text.contains("stalls: 2, longest 72.00 ms"), "\(report.text)")
    #expect(report.text.contains("72.00 ms in open W2"), "\(report.text)")
    #expect(report.text.contains("55.00 ms in launch"), "\(report.text)")
    #expect(!report.text.contains("OVER BUDGET"), "\(report.text)")
}

@Test func spanWithNoSamplesIsAnError() {
    var record = underBudget()
    record.openW2 = []
    #expect {
        try UIBenchReport(record: record)
    } throws: { error in
        String(describing: error).contains("open W2")
    }
}
