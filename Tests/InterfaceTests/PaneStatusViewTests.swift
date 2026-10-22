import AppKit
import Base
import Browser
import Foundation
import TestSupport
import Testing

@testable import Interface

/// The date the status views below take as now.
private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let fiveMinutesAgo = now.addingTimeInterval(-300)
private let album = Location(path: "/net/nas/music/album")

/// A status view whose spinner waits on `clock`, with the time fixed at `now` unless
/// `currentDate` says otherwise.
@MainActor
private func statusView(
    clock: ManualClock, currentDate: @escaping @MainActor () -> Date = { now }
) -> PaneStatusView {
    PaneStatusView(clock: clock, now: currentDate)
}

/// A listing of one file, built off the main thread as a listing must be.
private func someRows() async -> Listing {
    await Task.detached { Listing([file("track.flac")]) }.value
}

/// Rows a slow or offline pane keeps, listed at `listedAt`.
private func kept(listedAt: Date?, isComplete: Bool = true) async -> ListingState.KeptRows {
    ListingState.KeptRows(listing: await someRows(), listedAt: listedAt, isComplete: isComplete)
}

/// Gives the status view's spinner task a chance to run after a clock advance.
@MainActor
private func letTasksRun() async {
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(20))
}

@MainActor @Test func cachedRowsShowTheSpinnerOnlyOnceTheClockPasses150ms() async throws {
    let clock = ManualClock()
    let view = statusView(clock: clock)

    view.show(
        .cachedRefreshing(await someRows(), listedAt: fiveMinutesAgo), location: album,
        volumeName: "music")
    clock.advance(by: LoadTimeouts.spinnerDelay - .milliseconds(1))
    await letTasksRun()

    #expect(view.spinner.isHidden)
    #expect(view.note.isHidden)

    clock.advance(by: .milliseconds(1))
    await settle { !view.spinner.isHidden }
    #expect(view.note.isHidden)
}

@MainActor @Test func slowShowsTheNoteWithTheVolumeNameAndWhenTheRowsWereListed() async throws {
    let clock = ManualClock()
    let view = statusView(clock: clock)

    view.show(.slow(await kept(listedAt: fiveMinutesAgo)), location: album, volumeName: "music")

    #expect(!view.note.isHidden)
    #expect(view.note.stringValue == "music is slow to answer. Listed 5 minutes ago.")
    clock.advance(by: LoadTimeouts.spinnerDelay)
    await settle { !view.spinner.isHidden }
}

@MainActor @Test func offlineShowsTheNoteAndNoSpinner() async throws {
    let clock = ManualClock()
    let view = statusView(clock: clock)

    view.show(
        .offline(await kept(listedAt: fiveMinutesAgo, isComplete: false)), location: album,
        volumeName: "music")
    clock.advance(by: LoadTimeouts.spinnerDelay)
    await letTasksRun()

    #expect(view.note.stringValue == "music is offline. Listed 5 minutes ago.")
    #expect(!view.note.isHidden)
    #expect(view.spinner.isHidden)
}

@MainActor @Test func theNoteSaysWhenItShowsPartOfTheFolderOrNoRows() async throws {
    let view = statusView(clock: ManualClock())

    view.show(
        .offline(await kept(listedAt: nil, isComplete: false)), location: album,
        volumeName: "music")
    #expect(view.note.stringValue == "music is offline. Showing part of the folder.")

    view.show(.offline(nil), location: album, volumeName: "music")
    #expect(view.note.stringValue == "music is offline.")

    view.show(.slow(nil), location: album, volumeName: "music")
    #expect(view.note.stringValue == "music is slow to answer.")
}

@MainActor @Test func rowsListedUnderAMinuteAgoWereListedJustNow() async throws {
    let view = statusView(clock: ManualClock())

    view.show(
        .offline(await kept(listedAt: now.addingTimeInterval(-20))), location: album,
        volumeName: "music")

    #expect(view.note.stringValue == "music is offline. Listed just now.")
}

@MainActor @Test func theAgeIsInEnglishOnAGermanSystem() async {
    let text = PaneStatusText(systemLocale: Locale(identifier: "de_DE"))

    let note = text.note(
        for: .offline(await kept(listedAt: fiveMinutesAgo)), volumeName: "music", now: now)

    #expect(note == "music is offline. Listed 5 minutes ago.")
}

@MainActor @Test func loadedHidesTheSpinnerAndTheNote() async throws {
    let clock = ManualClock()
    let view = statusView(clock: clock)
    let rows = await someRows()
    view.show(.slow(nil), location: album, volumeName: "music")
    clock.advance(by: LoadTimeouts.spinnerDelay)
    await settle { !view.spinner.isHidden }

    view.show(.loaded(rows), location: album, volumeName: nil)

    #expect(view.spinner.isHidden)
    #expect(view.note.isHidden)
}

@MainActor @Test func aLoadThatLandsBeforeTheDelayNeverShowsTheSpinner() async throws {
    let clock = ManualClock()
    let view = statusView(clock: clock)
    let rows = await someRows()

    view.show(.loading, location: album, volumeName: nil)
    view.show(.loaded(rows), location: album, volumeName: nil)
    clock.advance(by: LoadTimeouts.spinnerDelay)
    await letTasksRun()

    #expect(view.spinner.isHidden)
}

/// A date a test moves forward by hand.
@MainActor
private final class CurrentDate {
    var value = now
}

/// The rows were listed 90 s before the note appeared, so it says one minute; 30 s later the
/// age reaches two minutes, and the note says so then, not a minute after it appeared.
@MainActor @Test func theNotesAgeChangesWhenTheListingTurnsAMinuteOlder() async throws {
    let clock = ManualClock()
    let date = CurrentDate()
    let view = statusView(clock: clock, currentDate: { date.value })
    view.show(
        .offline(await kept(listedAt: now.addingTimeInterval(-90))), location: album,
        volumeName: "music")
    #expect(view.note.stringValue == "music is offline. Listed 1 minute ago.")

    date.value = now.addingTimeInterval(30)
    clock.advance(by: .seconds(30))

    await settle { view.note.stringValue == "music is offline. Listed 2 minutes ago." }
}
