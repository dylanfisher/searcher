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

/// A row sheet with Finder's conflict buttons.
@MainActor
private func rowSheet(checkbox: NSButton? = nil, information: String = "More.")
    -> Dialog.RowSheet
{
    Dialog.rowSheet(
        message: "Replace?", information: information,
        buttons: ["Replace", "Skip", "Stop", "Keep Both"], escape: "Stop", checkbox: checkbox)
}

/// Where `view` is in its window, so views in different stacks compare.
@MainActor
private func frameInWindow(_ view: NSView) -> NSRect {
    view.convert(view.bounds, to: nil)
}

/// Where `view`'s content edges are in its window: a checkbox's frame is wider than its box,
/// and the stack lines views up by these.
@MainActor
private func alignmentInWindow(_ view: NSView) -> NSRect {
    view.convert(view.alignmentRect(forFrame: view.bounds), to: nil)
}

@MainActor @Test func aRowSheetPutsTheDefaultRightmostInOneRow() {
    let sheet = rowSheet()
    let row = sheet.buttons.sorted { frameInWindow($0).minX < frameInWindow($1).minX }

    #expect(row.map(\.title) == ["Keep Both", "Stop", "Skip", "Replace"])
    #expect(Set(row.map { frameInWindow($0).minY }).count == 1)
    #expect(sheet.buttons.map(\.keyEquivalent) == ["\r", "", "\u{1B}", ""])
    #expect(sheet.panel.initialFirstResponder === sheet.buttons[2])
}

/// Laid out like an alert: the app icon at alert size, the message bold at the system size
/// and the information at the small size, the window as big as its content.
@MainActor @Test func aRowSheetLooksLikeAnAlertAndFitsItsContent() throws {
    let short = rowSheet()
    let long = rowSheet(information: String(repeating: "A longer explanation. ", count: 20))
    let content = try #require(short.panel.contentView)

    #expect(short.icon.frame.size == NSSize(width: 64, height: 64))
    #expect(short.icon.imageScaling == .scaleProportionallyUpOrDown)
    #expect(short.messageLabel.font == .boldSystemFont(ofSize: NSFont.systemFontSize))
    #expect(short.informationLabel.font == .systemFont(ofSize: NSFont.smallSystemFontSize))
    #expect(content.frame.size == content.fittingSize)
    #expect(short.panel.frame.height < long.panel.frame.height)
    #expect(short.panel.frame.height < 200)
}

@MainActor @Test func aRowSheetsCheckboxSitsUnderTheTextOnlyWhenShown() {
    let box = NSButton(checkboxWithTitle: "Apply to All", target: nil, action: nil)
    let with = rowSheet(checkbox: box)
    let without = rowSheet()

    #expect(box.window === with.panel)
    #expect(alignmentInWindow(box).minX == alignmentInWindow(with.messageLabel).minX)
    #expect(frameInWindow(box).maxY < frameInWindow(with.informationLabel).minY)
    #expect(with.panel.frame.height > without.panel.frame.height)
}
