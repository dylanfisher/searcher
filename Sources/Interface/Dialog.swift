import AppKit

/// The one way the app asks the user something (docs/decisions/0076-dialogs.md): an `NSAlert`,
/// so every question has the system's layout, the app icon, and buttons sized and placed as
/// macOS places them. A question about a window's contents runs as a sheet on that window
/// through `sheet`; the quit question runs app-modal. A question whose buttons must stay in one
/// row, which NSAlert stacks from three on, uses `rowSheet`, laid out with the alert's icon,
/// fonts and margins.
@MainActor
enum Dialog {
    /// The title of the button that backs out. NSAlert gives a button with this title Esc.
    static let cancel = "Cancel"

    /// An alert saying `message`, with `information` under it, and a button for each of
    /// `buttons`. The first is the default: rightmost, or on top when the alert stacks its
    /// buttons, and Return presses it. `firstIsDestructive` marks it as one that loses data.
    static func alert(
        message: String, information: String? = nil, buttons: [String],
        firstIsDestructive: Bool = false
    ) -> NSAlert {
        precondition(!buttons.isEmpty, "an alert asking “\(message)” has no buttons")
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = information ?? ""
        for title in buttons {
            alert.addButton(withTitle: title)
        }
        alert.buttons[0].hasDestructiveAction = firstIsDestructive
        return alert
    }

    /// Readies `alert` to show as a sheet with `NSWindow.beginSheet`: its buttons send `action`
    /// to `target` instead of ending the alert, so the owner decides when it closes (Go to
    /// folder stays up for a folder that isn't there), and it is laid out to fit its text,
    /// accessory view and buttons. An owner that changes the alert's content lays it out again.
    static func sheet(_ alert: NSAlert, target: AnyObject, action: Selector) {
        for button in alert.buttons {
            button.target = target
            button.action = action
        }
        alert.layout()
    }

    /// A sheet from `rowSheet`, and the views a test or owner reads.
    @MainActor struct RowSheet {
        let panel: NSPanel
        let icon: NSImageView
        let messageLabel: NSTextField
        let informationLabel: NSTextField
        /// In the order given to `rowSheet`, the default first.
        let buttons: [NSButton]

        /// Has every button send `action` to `target`.
        func send(_ action: Selector, to target: AnyObject) {
            for button in buttons {
                button.target = target
                button.action = action
            }
        }
    }

    /// How wide the text column is: NSAlert's text width.
    private static let textWidth: CGFloat = 300
    /// The window's margins and the gap between the icon and the text, as NSAlert's.
    private static let margin: CGFloat = 20
    /// The alert icon's side.
    private static let iconSize: CGFloat = 64
    /// The gap between push buttons in a row (Human Interface Guidelines).
    private static let buttonSpacing: CGFloat = 12

    /// The app's icon, as NSAlert shows it. The named image loads when drawn;
    /// `NSApplication.applicationIconImage` looks the icon up at once, which takes seconds in
    /// a test process with no bundle.
    private static var appIcon: NSImage {
        guard let image = NSImage(named: NSImage.applicationIconName) else {
            preconditionFailure("the system has no image named \(NSImage.applicationIconName)")
        }
        return image
    }

    /// A sheet laid out like an alert, the app icon to the left of the bold message and the
    /// information, with every button in one row along the bottom: the first of `buttons` is
    /// the default, rightmost, and Return presses it, and the rest go leftwards in order. The
    /// button titled `escape` takes Esc and, as in NSAlert, the keys under full keyboard
    /// access. `checkbox`, unless nil or hidden, sits under the text. The owner points the
    /// buttons at itself with `RowSheet.send`, shows the panel with `NSWindow.beginSheet` and
    /// ends it.
    static func rowSheet(
        message: String, information: String, buttons titles: [String], escape: String,
        checkbox: NSButton?
    ) -> RowSheet {
        precondition(titles.contains(escape), "“\(escape)” isn't one of \(titles)")
        let icon = NSImageView(image: Self.appIcon)
        // The named icon's own size is smaller than an alert's; scale it up as NSAlert does.
        icon.imageScaling = .scaleProportionallyUpOrDown
        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let informationLabel = NSTextField(wrappingLabelWithString: information)
        informationLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for label in [messageLabel, informationLabel] {
            label.isSelectable = false
            label.preferredMaxLayoutWidth = textWidth
        }
        let buttons = titles.map { title in
            let button = NSButton(title: title, target: nil, action: nil)
            button.bezelStyle = .push
            if title == escape { button.keyEquivalent = "\u{1B}" }
            return button
        }
        buttons[0].keyEquivalent = "\r"
        let text = NSStackView(
            views: [messageLabel, informationLabel] + (checkbox.map { [$0] } ?? []))
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 8
        text.detachesHiddenViews = true
        if checkbox != nil { text.setCustomSpacing(12, after: informationLabel) }
        let row = NSStackView(views: buttons.reversed())
        row.spacing = buttonSpacing
        for view in [icon, text, row] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        let content = NSView()
        content.addSubview(icon)
        content.addSubview(text)
        content.addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: iconSize),
            icon.heightAnchor.constraint(equalToConstant: iconSize),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            text.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: margin),
            text.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            messageLabel.widthAnchor.constraint(equalToConstant: textWidth),
            informationLabel.widthAnchor.constraint(equalToConstant: textWidth),
            row.topAnchor.constraint(greaterThanOrEqualTo: text.bottomAnchor, constant: margin),
            row.topAnchor.constraint(greaterThanOrEqualTo: icon.bottomAnchor, constant: margin),
            row.leadingAnchor.constraint(
                greaterThanOrEqualTo: content.leadingAnchor, constant: margin),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
        ])
        // The row sits as close under the text as the constraints above allow.
        let snug = row.topAnchor.constraint(equalTo: text.bottomAnchor, constant: margin)
        snug.priority = .defaultLow
        snug.isActive = true
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        panel.contentView = content
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(content.fittingSize)
        content.layoutSubtreeIfNeeded()
        panel.initialFirstResponder = buttons.first { $0.title == escape }
        return RowSheet(
            panel: panel, icon: icon, messageLabel: messageLabel,
            informationLabel: informationLabel, buttons: buttons)
    }
}
