import AppKit
import Base
import Browser

/// The Go to folder sheet: a path field over a pane's window. Return goes to the typed folder,
/// expanded by `PathInput`, and Esc cancels. The sheet stays up until the folder lists: one that
/// isn't there, or isn't a folder, shows why under the field and leaves the pane where it was.
@MainActor
final class GoToFolderSheet: NSObject, NSTextFieldDelegate {
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 440, height: 120), styleMask: [.titled],
        backing: .buffered, defer: true)
    let field = NSTextField(string: "")
    /// Why the last folder typed couldn't be gone to; hidden until then.
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    /// Runs once the sheet has closed, gone or cancelled.
    var onClose: (@MainActor () -> Void)?
    /// Signals a Return with nothing typed. Tests replace it.
    var beep: @MainActor () -> Void = { NSSound.beep() }

    private let pane: Pane
    /// Where `~` starts.
    private let home: String

    init(pane: Pane, home: String) {
        self.pane = pane
        self.home = home
        super.init()
        buildContent()
    }

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
        messageLabel.isHidden = true
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
            messageLabel.stringValue = "There’s no folder at “\(error.path)”."
        case .notADirectory:
            messageLabel.stringValue = "“\(error.path)” isn’t a folder."
        case .privacyProtected, .permissionDenied, .unreachable, .other:
            preconditionFailure("the pane stayed for \(error), which it shows by moving")
        }
        messageLabel.isHidden = false
    }

    private func close() {
        panel.sheetParent?.endSheet(panel)
        onClose?()
    }

    @objc private func goClicked(_ sender: NSButton) {
        go()
    }

    @objc private func cancelClicked(_ sender: NSButton) {
        cancel()
    }

    private func buildContent() {
        let title = NSTextField(labelWithString: "Go to the folder:")
        field.delegate = self
        field.placeholderString = "~/Downloads"
        field.setAccessibilityLabel("Folder path")
        messageLabel.textColor = .systemRed
        messageLabel.isHidden = true
        let cancelButton = NSButton(
            title: "Cancel", target: self, action: #selector(cancelClicked(_:)))
        cancelButton.keyEquivalent = "\u{1B}"
        let goButton = NSButton(title: "Go", target: self, action: #selector(goClicked(_:)))
        goButton.keyEquivalent = "\r"
        let buttons = NSStackView()
        buttons.setViews([cancelButton, goButton], in: .trailing)
        let stack = NSStackView(views: [title, field, messageLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            messageLabel.widthAnchor.constraint(equalTo: field.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: field.widthAnchor),
            content.widthAnchor.constraint(equalToConstant: 440),
        ])
        stack.setCustomSpacing(16, after: messageLabel)
        panel.contentView = content
        panel.initialFirstResponder = field
    }
}
