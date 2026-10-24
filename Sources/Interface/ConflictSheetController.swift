import AppKit
import Browser

/// The sheet that asks what to do with an item whose name the destination folder already has,
/// as Finder asks it: keep both, stop the operation, skip this item, or replace the one there,
/// in one row with Replace the default (Return) and Stop on Esc. Under Finder's question are
/// each item's size and date as the plan read them. "Apply to All" applies the answer to the
/// operation's later conflicts, and shows only when there are some. A `Dialog.rowSheet`, since
/// NSAlert would stack four buttons (docs/decisions/0076-dialogs.md).
@MainActor
final class ConflictSheetController: NSObject {
    let dialog: Dialog.RowSheet
    let applyToAllBox = NSButton(checkboxWithTitle: "Apply to All", target: nil, action: nil)
    let request: ConflictRequest
    /// Gets the answer, or nil for Stop, once.
    private let answer: @MainActor (ConflictResolution?) -> Void

    /// The buttons' titles, the default first and then leftwards, as `Dialog.rowSheet` takes
    /// them.
    private static let titles = ["Replace", "Skip", "Stop", "Keep Both"]

    init(
        request: ConflictRequest, formatter: EntryCellFormatter = .init(),
        answer: @escaping @MainActor (ConflictResolution?) -> Void
    ) {
        self.request = request
        self.answer = answer
        let name = Location(path: request.existing.path).name
        applyToAllBox.isHidden = request.remaining == 0
        dialog = Dialog.rowSheet(
            message: "An item named “\(name)” already exists in this location.",
            information: """
                Do you want to replace it with the one you’re adding?
                The one there: \(Self.describe(request.existing, formatter))
                The one coming in: \(Self.describe(request.source, formatter))
                """,
            buttons: Self.titles, escape: "Stop", checkbox: applyToAllBox)
        super.init()
        dialog.send(#selector(pressed(_:)), to: self)
    }

    /// The window shown as the sheet.
    var panel: NSWindow { dialog.panel }
    var replaceButton: NSButton { dialog.buttons[0] }
    var skipButton: NSButton { dialog.buttons[1] }
    var stopButton: NSButton { dialog.buttons[2] }
    var keepBothButton: NSButton { dialog.buttons[3] }

    @objc private func pressed(_ sender: NSButton) {
        let choice: ConflictResolution.Choice
        switch sender {
        case replaceButton: choice = .replace
        case skipButton: choice = .skip
        case keepBothButton: choice = .keepBoth
        case stopButton:
            answer(nil)
            return
        default: preconditionFailure("\(sender.title) isn't one of the conflict's choices")
        }
        let appliesToAll = !applyToAllBox.isHidden && applyToAllBox.state == .on
        answer(ConflictResolution(choice: choice, appliesToAll: appliesToAll))
    }

    /// "1 KB, modified Today at 9:41 AM", or "Folder, modified …".
    private static func describe(
        _ item: ConflictRequest.Item, _ formatter: EntryCellFormatter
    ) -> String {
        let size =
            if item.isFolder { "Folder" } else if let bytes = item.bytes {
                formatter.bytes(bytes)
            } else { "Item" }
        return "\(size), modified \(formatter.date(item.modified))"
    }
}
