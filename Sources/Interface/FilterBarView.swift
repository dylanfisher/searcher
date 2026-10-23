import AppKit
import Browser

/// A pane's filter field, above its list. Each change of its text is reported, so the pane narrows
/// the rows as the user types. While it has focus every key edits its text, Cmd-A included,
/// except ↑ and ↓, which it hands back to move the list's selection, and Esc, which ends the
/// filter (0037-type-to-filter.md).
@MainActor
final class FilterBarView: NSView, NSSearchFieldDelegate {
    static let height: CGFloat = 28
    /// What VoiceOver calls the field.
    static let fieldLabel = "Filter by name"

    /// The line over a fully listed folder with no names matching `query`, and what VoiceOver
    /// hears for it.
    static func noMatchMessage(_ query: String) -> String {
        "No items match “\(query)”."
    }

    /// Posts an accessibility notification. Tests replace it to record what would be posted.
    var postAccessibility:
        @MainActor (
            Any, NSAccessibility.Notification, [NSAccessibility.NotificationUserInfoKey: Any]?
        )
            -> Void = { element, notification, userInfo in
                NSAccessibility.post(
                    element: element, notification: notification, userInfo: userInfo)
            }

    let field = NSSearchField()
    /// Runs with the field's text after each change, typed or cleared with its button.
    var onChange: (@MainActor (String) -> Void)?
    /// Runs with ↑ or ↓ pressed in the field.
    var onArrow: (@MainActor (KeyChord) -> Void)?
    /// Runs on Tab in the field, and returns whether a command took it; if none did, the field
    /// moves the key view as usual.
    var onTab: @MainActor () -> Bool = { false }
    /// Runs on Esc in the field.
    var onCancel: (@MainActor () -> Void)?
    /// Whether a chord runs Filter, so pressing it again in the field selects the field's text.
    var isFilterChord: @MainActor (KeyChord) -> Bool = { _ in false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.placeholderString = ViewCommands.filter.title
        field.setAccessibilityLabel(Self.fieldLabel)
        field.delegate = self
        // The clear button sends the action; typing reaches `controlTextDidChange`.
        field.target = self
        field.action = #selector(fieldChanged(_:))
        field.sendsSearchStringImmediately = true
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FilterBarView is built in code")
    }

    /// Filter's key while the field has focus selects the field's text, as Finder's and Safari's
    /// Find do. The menu item can't: the list, which runs commands, isn't in the field's responder
    /// chain, so the item is disabled. The window asks its views before the menu.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let editor = field.currentEditor(),
            KeyChord.candidates(for: event).contains(where: isFilterChord)
        else { return super.performKeyEquivalent(with: event) }
        editor.selectAll(nil)
        return true
    }

    /// Tells VoiceOver how many rows the filter `query` left: "2 items", or the no-match line.
    /// Called once a filtered listing lands, not per key, so only the latest query is read.
    func announceResult(count: Int, query: String) {
        let text =
            switch count {
            case 0: Self.noMatchMessage(query)
            case 1: "1 item"
            default: "\(count.formatted()) items"
            }
        postAccessibility(
            field, .announcementRequested,
            [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func controlTextDidChange(_ notification: Notification) {
        onChange?(field.stringValue)
    }

    @objc private func fieldChanged(_ sender: NSSearchField) {
        onChange?(field.stringValue)
    }

    /// ↑, ↓, Tab and Esc in the field; every other key edits the text.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
        -> Bool
    {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            onArrow?(KeyChord(.up))
            return true
        case #selector(NSResponder.moveDown(_:)):
            onArrow?(KeyChord(.down))
            return true
        case #selector(NSResponder.insertTab(_:)):
            return onTab()
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }
}
