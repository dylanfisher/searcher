import AppKit
import Browser

/// The sheet that asks yes or no before something happens: a copy or move to the other pane
/// ("Copy 2 items to “Folder”?"), or deleting items at once on a volume without a Trash. A
/// `Dialog` alert: the confirm button is the default, which Return presses, and Esc cancels.
@MainActor
final class ConfirmSheetController: NSObject {
    let alert: NSAlert
    let request: ConfirmRequest
    /// Gets true for the confirm button or Return, false for Cancel or Esc.
    private let answer: @MainActor (Bool) -> Void

    init(request: ConfirmRequest, answer: @escaping @MainActor (Bool) -> Void) {
        self.request = request
        self.answer = answer
        let (message, detail, confirmTitle) = Self.words(for: request)
        let isDelete = if case .deleteImmediately = request { true } else { false }
        alert = Dialog.alert(
            message: message, information: detail, buttons: [confirmTitle, Dialog.cancel],
            firstIsDestructive: isDelete)
        super.init()
        Dialog.sheet(alert, target: self, action: #selector(pressed(_:)))
    }

    /// The window shown as the sheet.
    var panel: NSWindow { alert.window }
    var confirmButton: NSButton { alert.buttons[0] }
    var cancelButton: NSButton { alert.buttons[1] }

    @objc private func pressed(_ sender: NSButton) {
        answer(sender === confirmButton)
    }

    /// The message, the detail and the confirm button's title for `request`.
    private static func words(for request: ConfirmRequest) -> (String, String?, String) {
        switch request {
        case .otherPane(.copy(let paths, let folder)):
            ("Copy \(items(paths)) to \(OperationRowView.quoted(folder))?", nil, "Copy")
        case .otherPane(.move(let paths, let folder)):
            ("Move \(items(paths)) to \(OperationRowView.quoted(folder))?", nil, "Move")
        case .otherPane(let operation):
            preconditionFailure("the other-pane confirm asked about \(operation)")
        case .deleteImmediately(let paths, _):
            (
                "Delete immediately? This can’t be undone.",
                paths.count == 1
                    ? "\(items(paths)) is on a volume without a Trash."
                    : "These \(items(paths)) are on a volume without a Trash.",
                "Delete"
            )
        }
    }

    private static func items(_ paths: [String]) -> String {
        OperationRowView.items(paths)
    }
}
