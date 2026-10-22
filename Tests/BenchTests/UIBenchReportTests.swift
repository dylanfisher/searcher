import Base
import Testing

@testable import Bench

/// A record with every span under its budget and no stalls; tests change one span.
private func underBudget() -> UIBenchRecord {
    UIBenchRecord(
        launch: [200, 210], openW1: [10, 12], openW2: [30, 40],
        keyDown: Array(repeating: 4, count: 500), optionArrows: Array(repeating: 5, count: 200),
        controlShiftDown: Array(repeating: 5, count: 200),
        pageDown: Array(repeating: 6, count: 200),
        shiftDown: Array(repeating: 5, count: 200), selectAll: Array(repeating: 6, count: 100),
        patchAllSelected: Array(repeating: 7, count: 100),
        reloadAllSelected: Array(repeating: 8, count: 20),
        patchAddingAllSelected: Array(repeating: 7, count: 100),
        clickHalf: Array(repeating: 9, count: 100),
        patchAfterShiftDown: Array(repeating: 9, count: 100),
        loadAfterSelectAll: Array(repeating: 9, count: 20),
        typeSelect: Array(repeating: 5, count: 24), sortChange: [90, 100],
        hiddenToggle: [40, 50], foldersFirstToggle: [40, 50], sortKey: [60, 70],
        filterKey: Array(repeating: 20, count: 24), columnDown: Array(repeating: 6, count: 500),
        columnRight: Array(repeating: 6, count: 100), columnLeft: Array(repeating: 6, count: 100),
        stalls: [])
}

@Test func filterKeysAreTheirOwnB7Case() throws {
    var record = underBudget()
    record.filterKey = Array(repeating: 60, count: 24)
    let report = try UIBenchReport(record: record, scenario: nil)
    #expect(report.overBudget.map(\.name) == ["W2 filter key → frame"])
    #expect(report.overBudget.map { $0.budget?.id } == ["B7"])
}

@Test func keyDownUnderB6Passes() throws {
    let report = try UIBenchReport(record: underBudget(), scenario: nil)
    #expect(report.passed)
    #expect(report.cases.first { $0.budget?.id == "B6" }?.samples.count == 500)
}

@Test func keyDownOverB6FailsNamingIt() throws {
    var record = underBudget()
    // 30 of 500 over 16 ms puts the p95 over.
    record.keyDown = Array(repeating: 4, count: 470) + Array(repeating: 25, count: 30)
    let report = try UIBenchReport(record: record, scenario: nil)
    #expect(!report.passed)
    #expect(report.overBudget.map { $0.budget?.id } == ["B6"])
}

@Test func eachRowCommandIsItsOwnB6Case() throws {
    var record = underBudget()
    record.pageDown = Array(repeating: 25, count: 200)
    let report = try UIBenchReport(record: record, scenario: nil)
    #expect(report.cases.filter { $0.budget?.id == "B6" }.count == 16)
    #expect(report.overBudget.map(\.name) == ["W2 Fn-↓ key → frame"])
}

@Test func typeSelectKeysAreTheirOwnB6Case() throws {
    var record = underBudget()
    record.typeSelect = Array(repeating: 25, count: 24)
    let report = try UIBenchReport(record: record, scenario: nil)
    #expect(report.overBudget.map(\.name) == ["W2 type-select key → frame"])
    #expect(report.overBudget.map { $0.budget?.id } == ["B6"])
}

@Test func stallsAreReportedWithTheirSpanAndDontFail() throws {
    var record = underBudget()
    record.stalls = [
        UIBenchRecord.Stall(milliseconds: 55, span: "launch"),
        UIBenchRecord.Stall(milliseconds: 72, span: "open W2"),
    ]
    let report = try UIBenchReport(record: record, scenario: nil)
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
        try UIBenchReport(record: record, scenario: nil)
    } throws: { error in
        String(describing: error).contains("open W2")
    }
}

@Test func columnViewKeysAreTheirOwnB6Cases() throws {
    var record = underBudget()
    // 30 of 500 over 16 ms puts the p95 over.
    record.columnDown = Array(repeating: 4, count: 470) + Array(repeating: 25, count: 30)
    let report = try UIBenchReport(record: record, scenario: nil)
    #expect(report.overBudget.map(\.name) == ["W2 column view ↓ through folders → frame"])
    #expect(report.overBudget.map { $0.budget?.id } == ["B6"])
}
