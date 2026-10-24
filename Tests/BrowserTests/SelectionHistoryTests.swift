import Base
import TestSupport
import Testing

@testable import Browser

private let here = Location(path: "/here")
private let there = Location(path: "/there")

private func only(_ name: String) -> Selection {
    Selection([ExactName(name)], cursor: ExactName(name))
}

@Test func undoReturnsTheSelectionBeforeTheChangeAndRedoTheOneAfter() {
    var history = SelectionHistory(clock: ManualClock())
    #expect(!history.canUndo(in: here))

    history.record(only("a"), in: here, by: .once)

    #expect(history.canUndo(in: here))
    #expect(!history.canRedo(in: here))
    #expect(history.undo(only("b"), in: here) == only("a"))
    #expect(!history.canUndo(in: here))
    #expect(history.redo(only("a"), in: here) == only("b"))
    #expect(history.undo(only("b"), in: here) == only("a"))
}

@Test func aNewChangeEndsTheWayForward() {
    var history = SelectionHistory(clock: ManualClock())
    history.record(only("a"), in: here, by: .once)
    _ = history.undo(only("b"), in: here)
    #expect(history.canRedo(in: here))

    history.record(only("a"), in: here, by: .once)

    #expect(!history.canRedo(in: here))
}

@Test func nothingSelectedWithNoCursorIsNotAStep() {
    var history = SelectionHistory(clock: ManualClock())

    history.record(Selection(), in: here, by: .once)

    #expect(!history.canUndo(in: here))
}

@Test func aHeldKeysRepeatsJoinItsPressAndEachTapIsAStep() {
    let clock = ManualClock()
    var history = SelectionHistory(clock: clock)
    let tap = SelectionHistory.Source.move(by: 1, extending: false, isRepeat: false)
    let repeated = SelectionHistory.Source.move(by: 1, extending: false, isRepeat: true)

    history.record(only("a"), in: here, by: tap)
    history.record(only("b"), in: here, by: repeated)
    clock.advance(by: .seconds(2))
    history.record(only("c"), in: here, by: repeated)
    history.record(only("d"), in: here, by: tap)
    history.record(only("e"), in: here, by: tap)

    for name in ["e", "d", "a"] {
        #expect(history.undo(only("z"), in: here) == only(name))
    }
    #expect(!history.canUndo(in: here))
}

@Test func aRepeatOfAnotherKeyIsAStep() {
    var history = SelectionHistory(clock: ManualClock())

    history.record(only("a"), in: here, by: .move(by: 1, extending: false, isRepeat: false))
    history.record(only("b"), in: here, by: .move(by: 1, extending: true, isRepeat: true))

    #expect(history.undo(only("c"), in: here) == only("b"))
    #expect(history.undo(only("b"), in: here) == only("a"))
}

@Test func aTypeToSelectQueryIsOneStepUntilAPause() {
    let clock = ManualClock()
    var history = SelectionHistory(clock: clock)

    history.record(only("a"), in: here, by: .typing)
    clock.advance(by: .milliseconds(400))
    history.record(only("b"), in: here, by: .typing)
    clock.advance(by: SelectionHistory.queryPause)
    history.record(only("c"), in: here, by: .typing)

    #expect(history.undo(only("d"), in: here) == only("c"))
    #expect(history.undo(only("c"), in: here) == only("a"))
}

@Test func aPressIsOneStepHoweverLongItPauses() {
    let clock = ManualClock()
    var history = SelectionHistory(clock: clock)

    history.record(only("a"), in: here, by: .press(1))
    clock.advance(by: .seconds(2))
    history.record(only("b"), in: here, by: .press(1))

    #expect(history.undo(only("c"), in: here) == only("a"))
    #expect(!history.canUndo(in: here))
}

@Test func undoAndRedoSkipStepsThatRestoreNothingAndDropThem() {
    var history = SelectionHistory(clock: ManualClock())
    for name in ["a", "gone", "b", "gone"] {
        history.record(only(name), in: here, by: .once)
    }
    let restoring: (Selection) -> Selection? = { $0 == only("gone") ? nil : $0 }

    #expect(history.canUndo(in: here, restoring: restoring))
    #expect(history.undo(only("now"), in: here, restoring: restoring) == only("b"))
    #expect(history.undo(only("b"), in: here, restoring: restoring) == only("a"))
    #expect(!history.canUndo(in: here))
    #expect(history.redo(only("a"), in: here, restoring: restoring) == only("b"))
    #expect(history.redo(only("b"), in: here, restoring: restoring) == only("now"))
}

@Test func withOnlyStepsThatRestoreNothingThereIsNothingToUndo() {
    var history = SelectionHistory(clock: ManualClock())
    history.record(only("gone"), in: here, by: .once)

    #expect(!history.canUndo(in: here, restoring: { _ in nil }))
    #expect(history.undo(only("now"), in: here, restoring: { _ in nil }) == nil)
}

@Test func anotherSourceOrAOnceChangeStartsANewStep() {
    var history = SelectionHistory(clock: ManualClock())

    history.record(only("a"), in: here, by: .move(by: 1, extending: false, isRepeat: false))
    history.record(only("b"), in: here, by: .typing)
    history.record(only("c"), in: here, by: .press(1))
    history.record(only("d"), in: here, by: .once)
    history.record(only("e"), in: here, by: .once)

    for name in ["e", "d", "c", "b", "a"] {
        #expect(history.undo(only("z"), in: here) == only(name))
    }
}

@Test func onePressIsOneStepAndTheNextPressAnother() {
    var history = SelectionHistory(clock: ManualClock())

    history.record(only("a"), in: here, by: .press(1))
    history.record(only("b"), in: here, by: .press(1))
    history.record(only("c"), in: here, by: .press(2))

    #expect(history.undo(only("d"), in: here) == only("c"))
    #expect(history.undo(only("c"), in: here) == only("a"))
}

@Test func anUndoEndsTheRun() {
    var history = SelectionHistory(clock: ManualClock())
    history.record(only("a"), in: here, by: .move(by: 1, extending: false, isRepeat: false))
    _ = history.undo(only("b"), in: here)

    history.record(only("a"), in: here, by: .move(by: 1, extending: false, isRepeat: true))

    #expect(history.undo(only("b"), in: here) == only("a"))
}

@Test func theHistoryKeepsTheNewestLimitSteps() {
    var history = SelectionHistory(clock: ManualClock())
    for step in 0..<(SelectionHistory.limit + 5) {
        history.record(only("e\(step)"), in: here, by: .once)
    }

    var undone: [Selection] = []
    while let selection = history.undo(only("now"), in: here) {
        undone.append(selection)
    }

    #expect(undone.count == SelectionHistory.limit)
    #expect(undone.last == only("e5"))
}

@Test func eachFolderHasItsOwnSteps() {
    var history = SelectionHistory(clock: ManualClock())
    history.record(only("a"), in: here, by: .once)

    #expect(!history.canUndo(in: there))
    #expect(history.undo(only("x"), in: there) == nil)
    history.record(only("x"), in: there, by: .once)

    #expect(history.undo(only("b"), in: here) == only("a"))
    #expect(history.undo(only("y"), in: there) == only("x"))
}

@Test func onlyTheMostRecentFoldersKeepTheirSteps() {
    var history = SelectionHistory(clock: ManualClock())
    for folder in 0...SelectionHistory.folderLimit {
        history.record(only("a"), in: Location(path: "/f\(folder)"), by: .once)
    }

    #expect(!history.canUndo(in: Location(path: "/f0")))
    #expect(history.canUndo(in: Location(path: "/f1")))
    #expect(history.canUndo(in: Location(path: "/f\(SelectionHistory.folderLimit)")))
}
