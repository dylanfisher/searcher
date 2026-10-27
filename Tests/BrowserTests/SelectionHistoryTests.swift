import Base
import TestSupport
import Testing

@testable import Browser

private let left = PaneID()
private let right = PaneID()
private let here = Location(path: "/here")
private let there = Location(path: "/there")

private func only(_ name: String) -> Selection {
    Selection([ExactName(name)], cursor: ExactName(name))
}

/// `name` selected alone in `folder` of `pane`.
private func at(_ name: String, in folder: Location = here, of pane: PaneID = left)
    -> SelectionHistory.Position
{
    SelectionHistory.Position(pane: pane, folder: folder, selection: only(name))
}

extension SelectionHistory {
    /// Notes a change from `name` selected alone in `folder` of `pane`.
    fileprivate mutating func record(
        _ name: String, in folder: Location = here, of pane: PaneID = left,
        by source: Source = .once
    ) {
        record(at(name, in: folder, of: pane), by: source)
    }

    /// Steps back to the nearest step `restorable` accepts, with `current` selected in that
    /// step's pane and folder; returns the step.
    fileprivate mutating func undo(
        from current: String, where restorable: (Position) -> Bool = { _ in true }
    ) -> Position? {
        undo { step in
            restorable(step) ? (step, replacing: at(current, in: step.folder, of: step.pane)) : nil
        }
    }

    /// Steps forward, as `undo(from:where:)` steps back.
    fileprivate mutating func redo(
        from current: String, where restorable: (Position) -> Bool = { _ in true }
    ) -> Position? {
        redo { step in
            restorable(step) ? (step, replacing: at(current, in: step.folder, of: step.pane)) : nil
        }
    }
}

@Test func undoReturnsThePositionBeforeTheChangeAndRedoTheOneItReplaced() {
    var history = SelectionHistory(clock: ManualClock())
    #expect(!history.canUndo())

    history.record("a")

    #expect(history.canUndo())
    #expect(!history.canRedo())
    #expect(history.undo(from: "b") == at("a"))
    #expect(!history.canUndo())
    #expect(history.redo(from: "a") == at("b"))
    #expect(history.undo(from: "b") == at("a"))
}

@Test func aNewChangeEndsTheWayForward() {
    var history = SelectionHistory(clock: ManualClock())
    history.record("a")
    _ = history.undo(from: "b")
    #expect(history.canRedo())

    history.record("a")

    #expect(!history.canRedo())
}

@Test func nothingSelectedWithNoCursorIsNotAStep() {
    var history = SelectionHistory(clock: ManualClock())

    history.record(
        SelectionHistory.Position(pane: left, folder: here, selection: Selection()), by: .once)

    #expect(!history.canUndo())
}

/// A move of the keys is a step even from nothing selected: the focus is what changed.
@Test func aMoveOfTheKeysFromNothingSelectedIsAStep() {
    var history = SelectionHistory(clock: ManualClock())
    let empty = SelectionHistory.Position(pane: left, folder: here, selection: Selection())

    history.record(empty, by: .focus(.right, isRepeat: false), movingKeys: true)

    #expect(history.undo(from: "z") == empty)
}

/// A held focus key's repeats join its press wherever they move the keys; each press of it, or
/// of the focus key the other way, is a step of its own.
@Test func aHeldFocusKeysRepeatsJoinItsPressAcrossPanesAndColumns() {
    var history = SelectionHistory(clock: ManualClock())
    func move(
        _ name: String, in folder: Location, of pane: PaneID, _ direction: Direction,
        isRepeat: Bool
    ) {
        history.record(
            at(name, in: folder, of: pane), by: .focus(direction, isRepeat: isRepeat),
            movingKeys: true)
    }

    move("a", in: here, of: left, .left, isRepeat: false)
    move("b", in: there, of: left, .left, isRepeat: true)
    move("c", in: here, of: right, .left, isRepeat: true)
    move("d", in: here, of: right, .left, isRepeat: false)
    move("e", in: there, of: right, .right, isRepeat: true)

    #expect(history.undo(from: "z") == at("e", in: there, of: right))
    #expect(history.undo(from: "z") == at("d", of: right))
    #expect(history.undo(from: "z") == at("a"))
    #expect(!history.canUndo())
}

/// One press is one step wherever it moves the keys: the selection it makes in the column or
/// pane it moves them to joins the move.
@Test func aPressJoinsItsMoveOfTheKeysInAnotherPaneAndFolder() {
    var history = SelectionHistory(clock: ManualClock())

    history.record(at("a"), by: .press(7), movingKeys: true)
    history.record("b", in: there, of: right, by: .press(7))

    #expect(history.undo(from: "z") == at("a"))
    #expect(!history.canUndo())
}

@Test func aHeldKeysRepeatsJoinItsPressAndEachTapIsAStep() {
    let clock = ManualClock()
    var history = SelectionHistory(clock: clock)
    let tap = SelectionHistory.Source.move(by: 1, extending: false, isRepeat: false)
    let repeated = SelectionHistory.Source.move(by: 1, extending: false, isRepeat: true)

    history.record("a", by: tap)
    history.record("b", by: repeated)
    clock.advance(by: .seconds(2))
    history.record("c", by: repeated)
    history.record("d", by: tap)
    history.record("e", by: tap)

    for name in ["e", "d", "a"] {
        #expect(history.undo(from: "z") == at(name))
    }
    #expect(!history.canUndo())
}

@Test func aRepeatOfAnotherKeyIsAStep() {
    var history = SelectionHistory(clock: ManualClock())

    history.record("a", by: .move(by: 1, extending: false, isRepeat: false))
    history.record("b", by: .move(by: 1, extending: true, isRepeat: true))

    #expect(history.undo(from: "c") == at("b"))
    #expect(history.undo(from: "b") == at("a"))
}

/// A held key's repeats join its press only in the pane and folder the press was in.
@Test func aRepeatInAnotherPaneOrFolderIsAStep() {
    var history = SelectionHistory(clock: ManualClock())
    let tap = SelectionHistory.Source.move(by: 1, extending: false, isRepeat: false)
    let repeated = SelectionHistory.Source.move(by: 1, extending: false, isRepeat: true)

    history.record("a", by: tap)
    history.record("b", of: right, by: repeated)
    history.record("c", in: there, of: right, by: repeated)

    #expect(history.undo(from: "z") == at("c", in: there, of: right))
    #expect(history.undo(from: "z") == at("b", of: right))
    #expect(history.undo(from: "z") == at("a"))
}

@Test func aTypeToSelectQueryIsOneStepUntilAPause() {
    let clock = ManualClock()
    var history = SelectionHistory(clock: clock)

    history.record("a", by: .typing)
    clock.advance(by: .milliseconds(400))
    history.record("b", by: .typing)
    clock.advance(by: SelectionHistory.queryPause)
    history.record("c", by: .typing)

    #expect(history.undo(from: "d") == at("c"))
    #expect(history.undo(from: "c") == at("a"))
}

@Test func aPressIsOneStepHoweverLongItPauses() {
    let clock = ManualClock()
    var history = SelectionHistory(clock: clock)

    history.record("a", by: .press(1))
    clock.advance(by: .seconds(2))
    history.record("b", by: .press(1))

    #expect(history.undo(from: "c") == at("a"))
    #expect(!history.canUndo())
}

@Test func undoAndRedoSkipStepsThatRestoreNothingAndDropThem() {
    var history = SelectionHistory(clock: ManualClock())
    for name in ["a", "gone", "b", "gone"] {
        history.record(name)
    }
    let restorable: (SelectionHistory.Position) -> Bool = { $0 != at("gone") }

    #expect(history.canUndo(where: restorable))
    #expect(history.undo(from: "now", where: restorable) == at("b"))
    #expect(history.undo(from: "b", where: restorable) == at("a"))
    #expect(!history.canUndo())
    #expect(history.redo(from: "a", where: restorable) == at("b"))
    #expect(history.redo(from: "b", where: restorable) == at("now"))
}

@Test func withOnlyStepsThatRestoreNothingThereIsNothingToUndo() {
    var history = SelectionHistory(clock: ManualClock())
    history.record("gone")

    #expect(!history.canUndo(where: { _ in false }))
    #expect(history.undo(from: "now", where: { _ in false }) == nil)
}

@Test func anotherSourceOrAOnceChangeStartsANewStep() {
    var history = SelectionHistory(clock: ManualClock())

    history.record("a", by: .move(by: 1, extending: false, isRepeat: false))
    history.record("b", by: .typing)
    history.record("c", by: .press(1))
    history.record("d", by: .once)
    history.record("e", by: .once)

    for name in ["e", "d", "c", "b", "a"] {
        #expect(history.undo(from: "z") == at(name))
    }
}

@Test func onePressIsOneStepAndTheNextPressAnother() {
    var history = SelectionHistory(clock: ManualClock())

    history.record("a", by: .press(1))
    history.record("b", by: .press(1))
    history.record("c", by: .press(2))

    #expect(history.undo(from: "d") == at("c"))
    #expect(history.undo(from: "c") == at("a"))
}

@Test func anUndoEndsTheRun() {
    var history = SelectionHistory(clock: ManualClock())
    history.record("a", by: .move(by: 1, extending: false, isRepeat: false))
    _ = history.undo(from: "b")

    history.record("a", by: .move(by: 1, extending: false, isRepeat: true))

    #expect(history.undo(from: "b") == at("a"))
}

/// Steps of every pane and folder are one history, newest first.
@Test func stepsOfEveryPaneAndFolderAreOneHistory() {
    var history = SelectionHistory(clock: ManualClock())
    history.record("a")
    history.record("x", in: there)
    history.record("r", of: right)

    #expect(history.undo(from: "s") == at("r", of: right))
    #expect(history.undo(from: "y") == at("x", in: there))
    #expect(history.undo(from: "b") == at("a"))
    #expect(history.redo(from: "a") == at("b"))
    #expect(history.redo(from: "x") == at("y", in: there))
    #expect(history.redo(from: "r") == at("s", of: right))
}

@Test func eachPaneKeepsItsNewestLimitSteps() {
    var history = SelectionHistory(clock: ManualClock())
    history.record("r", of: right)
    for step in 0..<(SelectionHistory.limit + 5) {
        history.record("e\(step)")
    }

    var undone: [SelectionHistory.Position] = []
    while let step = history.undo(from: "now") {
        undone.append(step)
    }

    #expect(undone.count == SelectionHistory.limit + 1)
    #expect(undone[SelectionHistory.limit - 1] == at("e5"))
    #expect(undone.last == at("r", of: right))
}

@Test func droppingAPanesStepsKeepsTheOthers() {
    var history = SelectionHistory(clock: ManualClock())
    history.record("a")
    history.record("r", of: right)
    history.record("b")
    _ = history.undo(from: "c")
    _ = history.undo(from: "s")

    history.dropSteps(of: right)

    #expect(history.undo(from: "b") == at("a"))
    #expect(history.redo(from: "a") == at("b"))
    #expect(history.redo(from: "b") == at("c"))
    #expect(!history.canRedo())
}

/// A held key's run in a pane whose steps were dropped ends there.
@Test func droppingAPanesStepsEndsItsRun() {
    var history = SelectionHistory(clock: ManualClock())
    history.record("a", by: .move(by: 1, extending: false, isRepeat: false))
    history.dropSteps(of: left)

    history.record("b", by: .move(by: 1, extending: false, isRepeat: true))

    #expect(history.undo(from: "c") == at("b"))
}

@Test func aPositionInAServersColumnIsKeptByTheServer() {
    let server = Location.server(Server(mountSource: "//HAL9000._smb._tcp.local/music")!)
    let sameServer = Location.server(Server(mountSource: "//guest@hal9000._smb._tcp.local/main")!)
    var history = SelectionHistory(clock: ManualClock())
    history.record("music", in: server)

    #expect(
        history.undo(from: "main", where: { $0.folder == sameServer }) == at("music", in: server))
    #expect(history.redo(from: "music") == at("main", in: server))
}
