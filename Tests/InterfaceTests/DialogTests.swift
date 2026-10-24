import AppKit
import Testing

@testable import Interface

/// Counts the presses `Dialog.sheet` sends it.
@MainActor
private final class Presses: NSObject {
    var titles: [String] = []

    @objc func pressed(_ sender: NSButton) {
        titles.append(sender.title)
    }
}

@MainActor @Test func theFirstButtonIsTheDefaultAndCancelTakesEsc() {
    let alert = Dialog.alert(
        message: "Copy “a” to “b”?", information: "More.", buttons: ["Copy", Dialog.cancel])

    #expect(alert.messageText == "Copy “a” to “b”?")
    #expect(alert.informativeText == "More.")
    #expect(alert.buttons.map(\.title) == ["Copy", "Cancel"])
    #expect(alert.buttons.map(\.keyEquivalent) == ["\r", "\u{1B}"])
    #expect(alert.buttons.allSatisfy { !$0.hasDestructiveAction })
}

@MainActor @Test func aDestructiveFirstButtonIsMarked() {
    let alert = Dialog.alert(
        message: "Delete?", buttons: ["Delete", Dialog.cancel], firstIsDestructive: true)

    #expect(alert.buttons.map(\.hasDestructiveAction) == [true, false])
}

@MainActor @Test func noInformationLeavesTheInformativeTextEmpty() {
    let alert = Dialog.alert(message: "Copy?", buttons: ["Copy", Dialog.cancel])

    #expect(alert.informativeText.isEmpty)
}

@MainActor @Test func aSheetsButtonsGoToItsTargetAndLeaveTheAlertUp() throws {
    let presses = Presses()
    let alert = Dialog.alert(message: "Copy?", buttons: ["Copy", Dialog.cancel])

    Dialog.sheet(alert, target: presses, action: #selector(Presses.pressed(_:)))
    alert.buttons[1].performClick(nil)
    #expect(alert.window.performKeyEquivalent(with: try keyEvent("\r")))

    #expect(presses.titles == ["Cancel", "Copy"])
}

/// Laid out by `sheet`, the alert is as big as its text and buttons: a short question is a
/// small window, not the fixed box the hand-built sheets were.
@MainActor @Test func aSheetIsLaidOutToFitItsContent() {
    let presses = Presses()
    let short = Dialog.alert(message: "Copy?", buttons: ["Copy", Dialog.cancel])
    let long = Dialog.alert(
        message: "Copy?", information: String(repeating: "A longer explanation. ", count: 20),
        buttons: ["Copy", Dialog.cancel])

    Dialog.sheet(short, target: presses, action: #selector(Presses.pressed(_:)))
    Dialog.sheet(long, target: presses, action: #selector(Presses.pressed(_:)))

    #expect(short.window.frame.height < long.window.frame.height)
    #expect(short.window.frame.height < 220)
    for button in short.buttons {
        #expect(button.window === short.window)
        #expect(button.frame.width > 0)
    }
}
