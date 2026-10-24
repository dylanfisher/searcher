import Base
import Foundation
import Testing

@Test func appendKeepsEverySampleOfBothLaunches() {
    var record = UIBenchRecord(
        launch: [1], openW1: [2], openW2: [3], keyDown: [4, 5], optionArrows: [11],
        controlShiftDown: [12], pageDown: [13], shiftDown: [14], typeSelect: [22], sortChange: [6],
        hiddenToggle: [17], foldersFirstToggle: [18], sortKey: [19], filterKey: [24], stalls: [])
    record.append(
        UIBenchRecord(
            launch: [7], openW1: [8], openW2: [9], keyDown: [], optionArrows: [15],
            controlShiftDown: [], pageDown: [16], shiftDown: [], typeSelect: [23], sortChange: [10],
            hiddenToggle: [20], foldersFirstToggle: [], sortKey: [21], filterKey: [25],
            stalls: [UIBenchRecord.Stall(milliseconds: 60, span: "launch")]))
    #expect(
        record
            == UIBenchRecord(
                launch: [1, 7], openW1: [2, 8], openW2: [3, 9], keyDown: [4, 5],
                optionArrows: [11, 15], controlShiftDown: [12], pageDown: [13, 16], shiftDown: [14],
                typeSelect: [22, 23], sortChange: [6, 10], hiddenToggle: [17, 20],
                foldersFirstToggle: [18],
                sortKey: [19, 21], filterKey: [24, 25],
                stalls: [UIBenchRecord.Stall(milliseconds: 60, span: "launch")]
            ))
}

@Test func recordSurvivesJSON() throws {
    let record = UIBenchRecord(
        launch: [1.5], openW1: [2], openW2: [3], keyDown: [4], optionArrows: [7],
        controlShiftDown: [8], pageDown: [9], shiftDown: [10], typeSelect: [14], sortChange: [6],
        hiddenToggle: [11], foldersFirstToggle: [12], sortKey: [13], filterKey: [15],
        stalls: [UIBenchRecord.Stall(milliseconds: 70, span: "sort change")])
    #expect(try UIBenchRecord.decode(record.encoded()) == record)
}

@Test func appendKeepsTheSplitSamples() {
    var record = UIBenchRecord(splitDown: [1], gridDown: [2], tenPaneOpen: [3])
    record.append(UIBenchRecord(splitDown: [], gridDown: [4], tenPaneOpen: [5]))
    #expect(record == UIBenchRecord(splitDown: [1], gridDown: [2, 4], tenPaneOpen: [3, 5]))
}

@Test func fewerThanATenthOfThePressesDuringTheCopyFails() {
    #expect {
        try UIBenchRecord.checkQueueKeyDown(kept: 49, of: 500)
    } throws: { error in
        String(describing: error) == "49 of 500 ↓ presses landed before the copy finished; need 50"
    }
}

@Test func aTenthOfThePressesDuringTheCopyPasses() throws {
    try UIBenchRecord.checkQueueKeyDown(kept: 50, of: 500)
    try UIBenchRecord.checkQueueKeyDown(kept: 500, of: 500)
}

@Test func splitSamplesSurviveJSON() throws {
    let record = UIBenchRecord(splitDown: [1.5], gridDown: [2], tenPaneOpen: [70])
    #expect(try UIBenchRecord.decode(record.encoded()) == record)
}

@Test func appendKeepsTheSidebarAndRestoredSessionSamples() throws {
    var record = UIBenchRecord(sidebarDown: [1], restoredSessionLaunch: [2])
    record.append(UIBenchRecord(sidebarDown: [3], restoredSessionLaunch: [4]))
    #expect(record == UIBenchRecord(sidebarDown: [1, 3], restoredSessionLaunch: [2, 4]))
    #expect(try UIBenchRecord.decode(record.encoded()) == record)
}

@Test func aRestoredSessionLaunchInTheCIRunIsFiledUnderItsOwnSpan() {
    var record = UIBenchRecord(launch: [200], openW1: [10])
    record.appendRestoredSession(
        UIBenchRecord(
            launch: [300], stalls: [UIBenchRecord.Stall(milliseconds: 60, span: "launch")]))
    #expect(
        record
            == UIBenchRecord(
                launch: [200], openW1: [10], restoredSessionLaunch: [300],
                stalls: [UIBenchRecord.Stall(milliseconds: 60, span: "launch")]))
}
