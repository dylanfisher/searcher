import Base
import Foundation
import Testing

@Test func appendKeepsEverySampleOfBothLaunches() {
    var record = UIBenchRecord(
        launch: [1], openW1: [2], openW2: [3], keyDown: [4, 5], sortChange: [6], stalls: [])
    record.append(
        UIBenchRecord(
            launch: [7], openW1: [8], openW2: [9], keyDown: [], sortChange: [10],
            stalls: [UIBenchRecord.Stall(milliseconds: 60, span: "launch")]))
    #expect(
        record
            == UIBenchRecord(
                launch: [1, 7], openW1: [2, 8], openW2: [3, 9], keyDown: [4, 5],
                sortChange: [6, 10], stalls: [UIBenchRecord.Stall(milliseconds: 60, span: "launch")]
            ))
}

@Test func recordSurvivesJSON() throws {
    let record = UIBenchRecord(
        launch: [1.5], openW1: [2], openW2: [3], keyDown: [4], sortChange: [6],
        stalls: [UIBenchRecord.Stall(milliseconds: 70, span: "sort change")])
    #expect(try UIBenchRecord.decode(record.encoded()) == record)
}
