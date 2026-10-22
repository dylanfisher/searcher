import AppKit
import Browser

/// A pane's filter field, above its list. Each change of its text is reported, so the pane narrows
/// the rows as the user types. While it has focus every key edits its text, Cmd-A included,
/// except ↑ and ↓, which it hands back to move the list's selection, and Esc, which ends the
/// filter (0037-type-to-filter.md).
@MainActor
final class FilterBarView: NSView, NSSearchFieldDelegate {
    static let height: CGFloat = 28

    let field = NSSearchField()
    /// Runs with the field's text after each change, typed or cleared with its button.
    var onChange: (@MainActor (String) -> Void)?
    /// Runs with ↑ or ↓ pressed in the field.
    var onArrow: (@MainActor (KeyChord) -> Void)?
    /// Runs on Esc in the field.
    var onCancel: (@MainActor () -> Void)?
    /// Whether a chord runs Filter, so pressing it again in the field selects the field's text.
    var isFilterChord: @MainActor (KeyChord) -> Bool = { _ in false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.placeholderString = ViewCommands.filter.title
        field.setAccessibilityLabel("Filter by name")
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

    func controlTextDidChange(_ notification: Notification) {
        onChange?(field.stringValue)
    }

    @objc private func fieldChanged(_ sender: NSSearchField) {
        onChange?(field.stringValue)
    }

    /// ↑, ↓ and Esc in the field; every other key edits the text.
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
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }
}
