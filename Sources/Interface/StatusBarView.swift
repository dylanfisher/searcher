import AppKit

/// A window's status bar: one line of secondary text centred along the window's bottom edge,
/// such as "6 items, 789.74 GB available", as Finder's status bar shows it
/// (docs/decisions/0131-status-bar.md). It shows what it's given and draws no background: the
/// window places it where the system draws its bottom bar.
@MainActor
final class StatusBarView: NSView {
    /// Finder's status bar is as tall as the path bar.
    static let height = PathBarView.height

    let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: Margin.standard),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -Margin.standard),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StatusBarView is built in code")
    }

    /// The line shown.
    var text: String {
        get { label.stringValue }
        set {
            if label.stringValue != newValue { label.stringValue = newValue }
        }
    }
}
