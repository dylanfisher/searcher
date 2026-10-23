import AppKit
import Browser

/// The sheet that asks yes or no before something happens: a copy or move to the other pane
/// ("Copy 2 items to “Folder”?"), or deleting items at once on a volume without a Trash. Return
/// confirms and Esc cancels.
@MainActor
final class ConfirmSheetController: NSObject {
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 140), styleMask: [.titled],
        backing: .buffered, defer: true)
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    /// What the question is about in more detail; hidden when the message says it all.
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let confirmButton = NSButton()
    let cancelButton = NSButton()

    let request: ConfirmRequest
    /// Gets true for the confirm button or Return, false for Cancel or Esc.
    private let answer: @MainActor (Bool) -> Void

    init(request: ConfirmRequest, answer: @escaping @MainActor (Bool) -> Void) {
        self.request = request
        self.answer = answer
        super.init()
        buildContent()
    }

    @objc private func confirm(_ sender: NSButton) {
        answer(true)
    }

    @objc private func cancel(_ sender: NSButton) {
        answer(false)
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

    private func buildContent() {
        let (message, detail, confirmTitle) = Self.words(for: request)
        messageLabel.stringValue = message
        messageLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = detail == nil
        confirmButton.title = confirmTitle
        cancelButton.title = "Cancel"
        for button in [confirmButton, cancelButton] {
            button.bezelStyle = .push
            button.target = self
        }
        confirmButton.action = #selector(confirm(_:))
        confirmButton.keyEquivalent = "\r"
        if case .deleteImmediately = request {
            confirmButton.hasDestructiveAction = true
        }
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1B}"
        let buttons = NSStackView()
        buttons.setViews([cancelButton, confirmButton], in: .trailing)
        let stack = NSStackView(views: [messageLabel, detailLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(16, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            messageLabel.widthAnchor.constraint(equalTo: buttons.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: buttons.widthAnchor),
            content.widthAnchor.constraint(equalToConstant: 420),
        ])
        panel.contentView = content
    }
}
