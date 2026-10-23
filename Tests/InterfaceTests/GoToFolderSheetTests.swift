import AppKit
import Base
import Browser
import BrowserTestSupport
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Interface

/// A loaded pane at `/home/me/work` and a Go to folder sheet over it that is never shown.
@MainActor
private struct Fixture {
    let pane: Pane
    let lister: GatedLister
    let sheet: GoToFolderSheet
    private let log = Log()

    @MainActor final class Log {
        var closes = 0
        var beeps = 0
    }

    var closeCount: Int { log.closes }
    var beepCount: Int { log.beeps }

    /// `held` paths list only once the test releases them.
    init(holding held: Set<String> = []) async {
        lister = GatedLister([
            "/home/me/work": .batches([[folder("src")]]),
            "/home/me/work/src": .batches([[file("main.swift")]]),
            "/home/me/Downloads": .batches([[file("a.zip")]]),
            "/home/me/gone": .failure(ListingError(path: "/home/me/gone", code: ENOENT)),
            "/home/me/work/notes.txt": .failure(
                ListingError(path: "/home/me/work/notes.txt", code: ENOTDIR)),
        ])
        for path in [
            "/home/me/work", "/home/me/work/src", "/home/me/Downloads", "/home/me/gone",
            "/home/me/work/notes.txt",
        ] where !held.contains(path) {
            lister.release(path)
        }
        let pane = Pane(
            location: Location(path: "/home/me/work"),
            service: ListingService(lister: lister, rootVolumeName: { "Test Disk" }),
            systemActions: StubSystemActions(), settings: untouchedSettings())
        self.pane = pane
        sheet = GoToFolderSheet(pane: pane, home: "/home/me")
        let log = log
        sheet.onClose = { log.closes += 1 }
        sheet.beep = { log.beeps += 1 }
        await settle { pane.state.isLoaded }
    }

    /// Types `text` and presses Return, as the field editor reports it.
    func go(_ text: String) {
        sheet.field.stringValue = text
        press(#selector(NSResponder.insertNewline(_:)))
    }

    func press(_ command: Selector) {
        #expect(sheet.control(sheet.field, textView: NSTextView(), doCommandBy: command))
    }
}

@MainActor @Test func returnGoesToTheTypedFolderAndCloses() async {
    let fixture = await Fixture()

    fixture.go("~/Downloads")
    await settle { fixture.closeCount == 1 }

    #expect(fixture.pane.location == Location(path: "/home/me/Downloads"))
    #expect(fixture.pane.state.isLoaded)
}

@MainActor @Test func aRelativePathGoesFromThePanesFolder() async {
    let fixture = await Fixture()

    fixture.go("src")
    await settle { fixture.closeCount == 1 }

    #expect(fixture.pane.location == Location(path: "/home/me/work/src"))
}

@MainActor
@Test(arguments: [
    ("../gone", "/home/me/gone"), ("notes.txt", "/home/me/work/notes.txt"),
])
func aMissingFolderShowsWhyWithThePathAndStaysOpen(typed: String, path: String) async {
    let fixture = await Fixture()

    fixture.go(typed)
    await settle { !fixture.sheet.messageLabel.isHidden }

    #expect(fixture.sheet.messageLabel.stringValue.contains("“\(path)”"))
    #expect(fixture.closeCount == 0)
    #expect(fixture.pane.location == Location(path: "/home/me/work"))
    #expect(fixture.pane.state.isLoaded)
}

@MainActor @Test func escapeClosesWithoutMovingThePane() async {
    let fixture = await Fixture()
    fixture.sheet.field.stringValue = "src"

    fixture.press(#selector(NSResponder.cancelOperation(_:)))
    await drainMainQueue()

    #expect(fixture.closeCount == 1)
    #expect(fixture.pane.location == Location(path: "/home/me/work"))
}

@MainActor @Test func escapeWhileAFolderListsStopsTheGo() async {
    let fixture = await Fixture(holding: ["/home/me/work/src"])
    fixture.go("src")
    #expect(await fixture.lister.waitForCall("/home/me/work/src"))

    fixture.press(#selector(NSResponder.cancelOperation(_:)))
    fixture.lister.release("/home/me/work/src")
    #expect(await fixture.lister.waitForFinished(2))
    await drainMainQueue()

    #expect(fixture.closeCount == 1)
    #expect(fixture.pane.location == Location(path: "/home/me/work"))
    #expect(fixture.pane.state.listing.map { $0[0].name } == "src")
}

@MainActor @Test func returnOnABlankFieldBeepsAndStaysOpen() async {
    let fixture = await Fixture()

    fixture.go("  ")

    #expect(fixture.beepCount == 1)
    #expect(fixture.closeCount == 0)
}

@MainActor @Test func otherEditingCommandsStayWithTheField() async {
    let fixture = await Fixture()

    #expect(
        !fixture.sheet.control(
            fixture.sheet.field, textView: NSTextView(),
            doCommandBy: #selector(NSResponder.moveLeft(_:))))
}

/// Returns once the main queue has run every block queued on it before this call.
@MainActor
private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}
