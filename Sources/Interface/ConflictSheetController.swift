import AppKit
import Browser

/// The sheet that asks what to do with an item whose name the destination folder already has:
/// replace the one there, skip this item, or keep both, with each item's size and date as the
/// plan read them. A box applies the answer to the operation's later conflicts, and shows only
/// when there are some. Return keeps both, since it loses nothing; Esc cancels the operation.
@MainActor
final class ConflictSheetController: NSObject {
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 460, height: 200), styleMask: [.titled],
        backing: .buffered, defer: true)
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    let existingLabel = NSTextField(wrappingLabelWithString: "")
    let sourceLabel = NSTextField(wrappingLabelWithString: "")
    let applyToAllBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let replaceButton = NSButton()
    let skipButton = NSButton()
    let keepBothButton = NSButton()
    let cancelButton = NSButton()

    let request: ConflictRequest
    /// Gets the answer, or nil for Cancel, once.
    private let answer: @MainActor (ConflictResolution?) -> Void
    private let formatter: EntryCellFormatter

    init(
        request: ConflictRequest, formatter: EntryCellFormatter = .init(),
        answer: @escaping @MainActor (ConflictResolution?) -> Void
    ) {
        self.request = request
        self.answer = answer
        self.formatter = formatter
        super.init()
        buildContent()
    }

    @objc private func choose(_ sender: NSButton) {
        let choice: ConflictResolution.Choice =
            switch sender {
            case replaceButton: .replace
            case skipButton: .skip
            case keepBothButton: .keepBoth
            default: preconditionFailure("\(sender.title) isn't one of the conflict's choices")
            }
        answer(ConflictResolution(choice: choice, appliesToAll: applyToAllBox.state == .on))
    }

    @objc private func cancel(_ sender: NSButton) {
        answer(nil)
    }

    /// "1 KB, modified Today at 9:41 AM", or "Folder, modified …".
    private func describe(_ item: ConflictRequest.Item) -> String {
        let size =
            if item.isFolder { "Folder" } else if let bytes = item.bytes {
                formatter.bytes(bytes)
            } else { "Item" }
        return "\(size), modified \(formatter.date(item.modified))"
    }

    private func buildContent() {
        let name = Location(path: request.existing.path).name
        let folder = Location(path: request.existing.path).parent?.name ?? "/"
        messageLabel.stringValue = "An item named “\(name)” is already in “\(folder)”."
        messageLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        existingLabel.stringValue = "The one there: \(describe(request.existing))"
        sourceLabel.stringValue = "The one coming in: \(describe(request.source))"
        let more = request.remaining
        applyToAllBox.title =
            more == 1 ? "Do the same for 1 more conflict" : "Do the same for \(more) more conflicts"
        applyToAllBox.isHidden = more == 0
        for (button, title) in [
            (cancelButton, "Cancel"), (skipButton, "Skip"), (replaceButton, "Replace"),
            (keepBothButton, "Keep Both"),
        ] {
            button.title = title
            button.bezelStyle = .push
            button.target = self
            button.action = #selector(choose(_:))
        }
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1B}"
        keepBothButton.keyEquivalent = "\r"
        let buttons = NSStackView()
        buttons.setViews([cancelButton], in: .leading)
        buttons.setViews([skipButton, replaceButton, keepBothButton], in: .trailing)
        let stack = NSStackView(views: [
            messageLabel, existingLabel, sourceLabel, applyToAllBox, buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(16, after: applyToAllBox)
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
            content.widthAnchor.constraint(equalToConstant: 460),
        ])
        panel.contentView = content
        panel.title = "Name in Use"
    }
}
