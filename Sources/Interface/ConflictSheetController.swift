import AppKit
import Browser

/// The sheet that asks what to do with an item whose name the destination folder already has:
/// replace the one there, skip this item, or keep both, with each item's size and date as the
/// plan read them. A `Dialog` alert: its suppression box applies the answer to the operation's
/// later conflicts, and shows only when there are some. Return keeps both, since it loses
/// nothing; Esc cancels the operation.
@MainActor
final class ConflictSheetController: NSObject {
    let alert: NSAlert
    let request: ConflictRequest
    /// Gets the answer, or nil for Cancel, once.
    private let answer: @MainActor (ConflictResolution?) -> Void

    init(
        request: ConflictRequest, formatter: EntryCellFormatter = .init(),
        answer: @escaping @MainActor (ConflictResolution?) -> Void
    ) {
        self.request = request
        self.answer = answer
        let name = Location(path: request.existing.path).name
        let folder = Location(path: request.existing.path).parent?.name ?? "/"
        alert = Dialog.alert(
            message: "An item named “\(name)” is already in “\(folder)”.",
            information: """
                The one there: \(Self.describe(request.existing, formatter))
                The one coming in: \(Self.describe(request.source, formatter))
                """,
            buttons: ["Keep Both", "Replace", "Skip", Dialog.cancel])
        super.init()
        alert.buttons[1].hasDestructiveAction = true
        let more = request.remaining
        alert.showsSuppressionButton = more > 0
        applyToAllBox.title =
            more == 1 ? "Do the same for 1 more conflict" : "Do the same for \(more) more conflicts"
        Dialog.sheet(alert, target: self, action: #selector(pressed(_:)))
    }

    /// The window shown as the sheet.
    var panel: NSWindow { alert.window }
    var keepBothButton: NSButton { alert.buttons[0] }
    var replaceButton: NSButton { alert.buttons[1] }
    var skipButton: NSButton { alert.buttons[2] }
    var cancelButton: NSButton { alert.buttons[3] }
    var applyToAllBox: NSButton {
        guard let box = alert.suppressionButton else {
            preconditionFailure("the conflict alert has no suppression button")
        }
        return box
    }

    @objc private func pressed(_ sender: NSButton) {
        let choice: ConflictResolution.Choice
        switch sender {
        case replaceButton: choice = .replace
        case skipButton: choice = .skip
        case keepBothButton: choice = .keepBoth
        case cancelButton:
            answer(nil)
            return
        default: preconditionFailure("\(sender.title) isn't one of the conflict's choices")
        }
        let appliesToAll = alert.showsSuppressionButton && applyToAllBox.state == .on
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
