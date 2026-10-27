import AppKit
import Base
import Browser

/// The Go to folder sheet: a `Dialog` alert over a pane's window with a path field as its
/// accessory view. Return or Go goes to the typed folder, expanded by `PathInput`, and Esc or
/// Cancel cancels. The sheet stays up until the folder lists: one that isn't there, or isn't a
/// folder, shows why under the field and leaves the pane where it was.
@MainActor
final class GoToFolderSheet: NSObject, NSTextFieldDelegate {
    let alert = Dialog.alert(message: "Go to the folder:", buttons: ["Go", Dialog.cancel])
    let field = NSTextField(string: "")
    /// Why the last folder typed couldn't be gone to; hidden until then.
    let messageLabel = Dialog.errorLabel()
    /// Runs once the sheet has closed, gone or cancelled.
    var onClose: (@MainActor () -> Void)?
    /// Signals a Return with nothing typed. Tests replace it.
    var beep: @MainActor () -> Void = { NSSound.beep() }

    /// How wide the path field is: about 45 characters of path.
    private static let fieldWidth: CGFloat = 320

    private let pane: Pane
    /// Where `~` starts.
    private let home: String

    init(pane: Pane, home: String) {
        self.pane = pane
        self.home = home
        super.init()
        buildContent()
    }

    /// The window shown as the sheet.
    var panel: NSWindow { alert.window }

    func present(over window: NSWindow) {
        window.beginSheet(panel)
    }

    /// Goes to the folder typed, from the pane's folder as it is now.
    func go() {
        guard let target = PathInput.location(for: field.stringValue, in: pane.location, home: home)
        else {
            beep()
            return
        }
        showMessage(nil)
        pane.goToFolder(target) { [weak self] error in
            guard let self else { return }
            if let error {
                show(error)
            } else {
                close()
            }
        }
    }

    /// Closes the sheet, stopping a go still waiting for its folder.
    func cancel() {
        pane.cancelGoToFolder()
        close()
    }

    /// Return and Esc in the field; every other key edits the text.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
        -> Bool
    {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            go()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }

    private func show(_ error: ListingError) {
        switch error.reason {
        case .notFound:
            showMessage("There’s no folder at “\(error.path)”.")
        case .notADirectory:
            showMessage("“\(error.path)” isn’t a folder.")
        case .privacyProtected, .permissionDenied, .unreachable, .other:
            preconditionFailure("the pane stayed for \(error), which it shows by moving")
        }
    }

    /// Shows `text` under the field, or hides the line for nil, and fits the sheet to it.
    private func showMessage(_ text: String?) {
        let isHidden = text == nil
        guard messageLabel.isHidden != isHidden || messageLabel.stringValue != (text ?? "") else {
            return
        }
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = isHidden
        layOut()
    }

    private func close() {
        panel.sheetParent?.endSheet(panel)
        onClose?()
    }

    @objc private func pressed(_ sender: NSButton) {
        if sender === alert.buttons[0] { go() } else { cancel() }
    }

    /// Fits the alert to what shows, and keeps the keys on the field, which the alert's layout
    /// gives to a button.
    private func layOut() {
        fitAccessory()
        alert.layout()
        panel.initialFirstResponder = field
    }

    /// Sizes the accessory view to the field and the line under it, if shown: the alert lays
    /// out the accessory by its frame.
    private func fitAccessory() {
        guard let accessory = alert.accessoryView else {
            preconditionFailure("the Go to folder alert has no accessory view")
        }
        accessory.setFrameSize(NSSize(width: Self.fieldWidth, height: accessory.fittingSize.height))
    }

    private func buildContent() {
        field.delegate = self
        field.placeholderString = "~/Downloads"
        field.setAccessibilityLabel("Folder path")
        messageLabel.isHidden = true
        let stack = NSStackView(views: [field, messageLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.detachesHiddenViews = true
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(equalToConstant: Self.fieldWidth),
            messageLabel.widthAnchor.constraint(equalTo: field.widthAnchor),
        ])
        alert.accessoryView = stack
        fitAccessory()
        Dialog.sheet(alert, target: self, action: #selector(pressed(_:)))
        panel.initialFirstResponder = field
    }
}
