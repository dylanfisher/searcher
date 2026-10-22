import Base
import Foundation
import TestSupport
import Testing

@testable import Browser

/// Files "r00" to "r24", sized so that by size, largest first, the order reverses.
private let entries25 = (0..<25).map { file(String(format: "r%02d", $0), size: Int64($0)) }

private func rows25() -> Listing {
    Listing(entries25)
}

private func name(_ row: Int) -> ExactName {
    ExactName(String(format: "r%02d", row))
}

private func names(_ rows: ClosedRange<Int>) -> Set<ExactName> {
    Set(rows.map(name))
}

/// A selection of row `row` alone, with the cursor and anchor on it.
private func at(_ row: Int) -> Selection {
    Selection([name(row)], cursor: name(row))
}

@Test func aMoveClampsAtBothEnds() {
    let listing = rows25()

    #expect(at(3).moved(by: 1, in: listing, extending: false) == at(4))
    #expect(at(3).moved(by: -10, in: listing, extending: false) == at(0))
    #expect(at(20).moved(by: 10, in: listing, extending: false) == at(24))
    #expect(at(0).moved(by: -1, in: listing, extending: false) == at(0))
    #expect(at(7).moved(toRow: 24, in: listing, extending: false) == at(24))
}

@Test func aMoveWithNoCursorStartsAtAnEnd() {
    let listing = rows25()

    #expect(Selection().moved(by: 1, in: listing, extending: false) == at(0))
    #expect(Selection().moved(by: 10, in: listing, extending: false) == at(0))
    #expect(Selection().moved(by: -1, in: listing, extending: false) == at(24))
}

@Test func anExtendingMoveSelectsFromTheAnchorToTheCursor() {
    let listing = rows25()

    let down = at(5).moved(by: 1, in: listing, extending: true)
        .moved(by: 1, in: listing, extending: true)
    #expect(down == Selection(names(5...7), cursor: name(7), anchor: name(5)))

    // Back toward the anchor shrinks the range, and past it grows the other way.
    let back = down.moved(by: -1, in: listing, extending: true)
    #expect(back == Selection(names(5...6), cursor: name(6), anchor: name(5)))
    let past = back.moved(by: -3, in: listing, extending: true)
    #expect(past == Selection(names(3...5), cursor: name(3), anchor: name(5)))
}

@Test func anExtendingMoveWithNoCursorSelectsOneRow() {
    let listing = rows25()

    #expect(Selection().moved(by: 1, in: listing, extending: true) == at(0))
}

@Test func aPlainMoveCollapsesSeveralRowsToOne() {
    let listing = rows25()
    let several = Selection(names(5...9), cursor: name(9), anchor: name(5))

    #expect(several.moved(by: 1, in: listing, extending: false) == at(10))
}

@Test func aMoveOnAnEmptyListingChangesNothing() {
    let empty = Listing([])
    let selection = at(3)

    #expect(selection.moved(by: 1, in: empty, extending: false) == selection)
    #expect(selection.moved(toRow: 0, in: empty, extending: true) == selection)
    #expect(Selection().moved(by: -1, in: empty, extending: false) == Selection())
}

@Test func rowsFollowTheListingsDisplayOrder() async {
    let bySize = await Task.detached {
        var listing = rows25()
        listing.sort(by: .size, ascending: false)
        return listing
    }.value
    let selection = Selection(names(2...3), cursor: name(3), anchor: name(2))

    #expect(selection.rows(in: rows25()) == IndexSet(2...3))
    #expect(selection.rows(in: bySize) == IndexSet(21...22))
    #expect(selection.cursorRow(in: bySize) == 21)
    // Shift-↓ by size moves to the next row in that order, "r02", the anchor.
    #expect(
        selection.moved(by: 1, in: bySize, extending: true)
            == Selection([name(2)], cursor: name(2), anchor: name(2)))
}

@Test func rowsOfALargeSelectionMatchOneByOneLookups() {
    let listing = rows25()
    let selection = Selection(names(0...19).union([ExactName("gone")]), cursor: name(19))

    #expect(selection.rows(in: listing) == IndexSet(0...19))
}

@Test func aCompleteLoadDropsNamesTheListingDoesNotHaveAndAPartialOneKeepsThem() {
    let listing = rows25()
    let selection = Selection(
        [name(1), ExactName("gone")], cursor: ExactName("gone"), anchor: name(1))

    #expect(
        selection.resolved(in: listing, after: .loaded(complete: true))
            == Selection([name(1)], cursor: nil, anchor: name(1)))
    // The rest of the folder may still hold them.
    #expect(selection.resolved(in: listing, after: .loaded(complete: false)) == selection)
}

@Test func allSelectsEveryRowAndKeepsTheCursor() {
    let listing = rows25()
    let all = at(4).all(in: listing)

    #expect(all == Selection(.allExcept([]), cursor: name(4), anchor: name(4)))
    #expect(all.rows(in: listing) == IndexSet(0...24))
}

@Test func entriesListedAfterSelectAllAreNotSelected() {
    let all = at(0).all(in: rows25())
    // "new" sorts first.
    let relisted = Listing(entries25 + [file("new")])

    let resolved = all.resolved(in: relisted, after: .loaded(complete: true))

    #expect(resolved.members == .allExcept([ExactName("new")]))
    #expect(!resolved.contains(ExactName("new")))
    #expect(resolved.rows(in: relisted) == IndexSet(1...25))
}

@Test func aFirstBatchAfterSelectAllExcludesNothingStillToCome() {
    let all = at(0).all(in: rows25())

    let partial = all.resolved(
        in: Listing(Array(entries25[0..<10])), after: .loaded(complete: false))
    #expect(partial.members == .allExcept([]))
    let full = partial.resolved(
        in: Listing(entries25 + [file("new")]), after: .loaded(complete: true))
    #expect(full.members == .allExcept([ExactName("new")]))
}

@Test func shiftAfterSelectAllDeselectsTheRowsTheRangeLeaves() {
    let listing = rows25()
    let all = at(10).moved(by: 2, in: listing, extending: true).all(in: listing)

    let shrunk = all.moved(by: -1, in: listing, extending: true)

    #expect(shrunk == Selection(.allExcept([name(12)]), cursor: name(11), anchor: name(10)))
    #expect(shrunk.rows(in: listing) == IndexSet(0...24).subtracting([12]))
}

/// Files "b0000" to "b3999": enough rows that a walk over all of them, or a lookup per selected
/// name, stands out in the work count.
private func rows4000() -> Listing {
    Listing((0..<4_000).map { file(String(format: "b%04d", $0)) })
}

private func big(_ row: Int) -> ExactName {
    ExactName(String(format: "b%04d", row))
}

#if DEBUG
    /// The work `body` does per entry, as `Selection.work` counts it.
    private func work(_ body: () -> Void) -> Int {
        let count = Selection.WorkCount()
        Selection.$work.withValue(count) { body() }
        return count.count
    }

    @Test func selectAllAndItsRowsTakeNoWorkPerEntry() {
        let listing = rows4000()
        let one = Selection([big(7)], cursor: big(7))
        var all = Selection()

        let cost = work {
            all = one.all(in: listing)
            _ = all.rows(in: listing)
            _ = all.all(in: listing) == all
        }

        #expect(cost == 0)
        #expect(all.rows(in: listing) == IndexSet(0..<4_000))
    }

    @Test func aPatchLandingWithEverythingSelectedTakesNoWorkPerEntry() {
        let listing = rows4000()
        let all = Selection([big(7)], cursor: big(7)).all(in: listing)
        var patched = listing
        patched.update(file("a-new"))
        patched.update(file("b0001", size: 9))
        var resolved = Selection()

        let cost = work { resolved = all.resolved(in: patched, after: .patched(added: ["a-new"])) }

        // Looking up the new entry, the cursor and the anchor.
        #expect(cost <= 3)
        #expect(resolved.members == .allExcept([ExactName("a-new")]))
        #expect(resolved.rows(in: patched) == IndexSet(1...4_000))
    }

    @Test func extendingALargeRangeWorksOnTheRowsThatChange() {
        let listing = rows4000()
        let range = Selection([big(0)], cursor: big(0))
            .moved(toRow: 3_000, in: listing, extending: true)
        var extended = range

        let cost = work {
            extended = range.moved(by: 1, in: listing, extending: true)
            extended = extended.moved(by: -2, in: listing, extending: true)
        }

        // Looking up the cursor and the anchor for each move.
        #expect(cost <= 4)
        #expect(extended.rows(in: listing) == IndexSet(0...2_999))
        #expect(
            extended == Selection(Set((0...2_999).map(big)), cursor: big(2_999), anchor: big(0)))
    }

    /// The main thread shows a selection the user changed while a patch ran; it checks only the
    /// rows near the cursor, and the rest are found when the selection settles off it.
    @Test func aProvisionalSelectionHasTheRowsNearTheCursorUntilItSettles() {
        let listing = rows4000()
        let half = Selection(Set((0..<2_000).map(big)), cursor: big(1_999))
            .resolved(in: listing, after: .sameEntries)
        var patched = listing
        patched.update(file("a-new"))
        var provisional = Selection()

        let cost = work {
            provisional = half.provisional(
                in: patched, after: .patched(added: ["a-new"]), radius: 5)
        }

        #expect(cost <= 20)
        #expect(!provisional.isSettled)
        // The cursor's row is 2000 now; of rows 1995...2005, those up to it are selected.
        #expect(provisional.rows(in: patched) == IndexSet(1_995...2_000))
        let settled = provisional.settled(in: patched)
        #expect(settled.isSettled)
        #expect(settled == half)
        #expect(settled.rows(in: patched) == IndexSet(1...2_000))
    }
#endif

@Test func aSelectionMadeByRowsIsNamedWhenItSettles() {
    let listing = rows25()
    let few = Selection(rows: IndexSet(2...4), in: listing, cursor: name(4), anchor: name(2))
    let most = Selection(rows: IndexSet(0...20), in: listing, cursor: name(20), anchor: name(0))

    #expect(!few.isSettled)
    #expect(few.contains(name(3)))
    #expect(!few.contains(name(5)))
    #expect(few.rows(in: listing) == IndexSet(2...4))
    #expect(
        few.settled(in: listing) == Selection(names(2...4), cursor: name(4), anchor: name(2)))
    // More than half the rows are named by the rows left out.
    let settledMost = most.settled(in: listing)
    #expect(settledMost.members == .allExcept(names(21...24)))
    #expect(settledMost.rows(in: listing) == IndexSet(0...20))
}

@Test func anExtendingMoveOnARowSelectionKeepsItsRowsAndNamesThemWhenItSettles() {
    let listing = rows25()
    let clicked = Selection(rows: IndexSet(2...4), in: listing, cursor: name(4), anchor: name(2))

    let moved = clicked.moved(by: 1, in: listing, extending: true)

    #expect(moved.rows(in: listing) == IndexSet(2...5))
    #expect(
        moved.settled(in: listing) == Selection(names(2...5), cursor: name(5), anchor: name(2)))
}

/// Moves made while the selection waits to settle are kept by name and applied over it, so a
/// row the range leaves stays deselected and the entry the load added stays out.
@Test func movesMadeWhileProvisionalApplyWhenTheSelectionSettles() {
    let all = at(10).all(in: rows25())
    // "new" sorts first.
    let relisted = Listing(entries25 + [file("new")])

    let moved = all.provisional(in: relisted, after: .loaded(complete: true), radius: 2)
        .moved(by: 1, in: relisted, extending: true)
        .moved(by: -2, in: relisted, extending: true)
    let settled = moved.settled(in: relisted)

    #expect(settled.isSettled)
    #expect(settled.members == .allExcept([name(11), ExactName("new")]))
    #expect(settled.cursor == name(9))
    #expect(settled.anchor == name(10))
    #expect(settled.rows(in: relisted) == IndexSet(1...25).subtracting([12]))
}

/// A first batch landing after a patch can't tell whether the folder still has what the patch
/// removed, so the names stay until a complete listing.
@Test func aFirstBatchAfterAPendingPatchKeepsTheNamesThePatchRemoved() {
    let listing = rows25()
    let selection = Selection([name(1), name(20)], cursor: name(1))
        .resolved(in: listing, after: .sameEntries)
    var patched = listing
    patched.remove(named: "r20")
    let partial = Listing(Array(entries25[0..<10]))

    let pending = selection.provisional(in: patched, after: .patched(added: []), radius: 1)
        .provisional(in: partial, after: .loaded(complete: false), radius: 1)

    #expect(pending.settled(in: partial).members == .only([name(1), name(20)]))
    #expect(pending.settled(in: partial).rows(in: partial) == [1])
}

/// Select All takes in neither patch's entry, though both are pending when it settles.
@Test func twoPendingPatchesUnderSelectAllExcludeWhatEachAdded() {
    let listing = rows25()
    let all = at(10).all(in: listing)
    var first = listing
    first.update(file("a1"))
    var second = first
    second.update(file("a2"))

    let settled = all.provisional(in: first, after: .patched(added: ["a1"]), radius: 1)
        .provisional(in: second, after: .patched(added: ["a2"]), radius: 1)
        .settled(in: second)

    #expect(settled.members == .allExcept([ExactName("a1"), ExactName("a2")]))
    #expect(!settled.contains(ExactName("a1")))
    #expect(settled.rows(in: second) == IndexSet(2...26))
}

/// A provisional selection answers for an entry its pending patch added before it settles.
@Test func aProvisionalSelectionUnderSelectAllDoesNotContainWhatAPendingPatchAdded() {
    let listing = rows25()
    let all = at(10).all(in: listing)
    var patched = listing
    patched.update(file("a1"))

    let provisional = all.provisional(in: patched, after: .patched(added: ["a1"]), radius: 1)

    #expect(!provisional.isSettled)
    #expect(!provisional.contains(ExactName("a1")))
    #expect(provisional.contains(name(3)))
}
