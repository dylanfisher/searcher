import AppKit

/// The one way the app asks the user something (docs/decisions/0076-dialogs.md): an `NSAlert`,
/// so every question has the system's layout, the app icon, and buttons sized and placed as
/// macOS places them. A question about a window's contents runs as a sheet on that window
/// through `sheet`; the quit question runs app-modal.
@MainActor
enum Dialog {
    /// The title of the button that backs out; Esc presses it.
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
            let button = alert.addButton(withTitle: title)
            if title == cancel {
                button.keyEquivalent = "\u{1B}"
            }
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
}
