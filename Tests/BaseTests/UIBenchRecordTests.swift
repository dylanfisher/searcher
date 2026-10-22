import Base
import Foundation
import Testing

@Test func appendKeepsEverySampleOfBothLaunches() {
    var record = UIBenchRecord(
        launch: [1], openW1: [2], openW2: [3], keyDown: [4, 5], optionArrows: [11],
        controlShiftDown: [12], pageDown: [13], shiftDown: [14], sortChange: [6],
        hiddenToggle: [17], foldersFirstToggle: [18], sortKey: [19], stalls: [])
    record.append(
        UIBenchRecord(
            launch: [7], openW1: [8], openW2: [9], keyDown: [], optionArrows: [15],
            controlShiftDown: [], pageDown: [16], shiftDown: [], sortChange: [10],
            hiddenToggle: [20], foldersFirstToggle: [], sortKey: [21],
            stalls: [UIBenchRecord.Stall(milliseconds: 60, span: "launch")]))
    #expect(
        record
            == UIBenchRecord(
                launch: [1, 7], openW1: [2, 8], openW2: [3, 9], keyDown: [4, 5],
                optionArrows: [11, 15], controlShiftDown: [12], pageDown: [13, 16], shiftDown: [14],
                sortChange: [6, 10], hiddenToggle: [17, 20], foldersFirstToggle: [18],
                sortKey: [19, 21], stalls: [UIBenchRecord.Stall(milliseconds: 60, span: "launch")]
            ))
}

@Test func recordSurvivesJSON() throws {
    let record = UIBenchRecord(
        launch: [1.5], openW1: [2], openW2: [3], keyDown: [4], optionArrows: [7],
        controlShiftDown: [8], pageDown: [9], shiftDown: [10], sortChange: [6],
        hiddenToggle: [11], foldersFirstToggle: [12], sortKey: [13],
        stalls: [UIBenchRecord.Stall(milliseconds: 70, span: "sort change")])
    #expect(try UIBenchRecord.decode(record.encoded()) == record)
}
