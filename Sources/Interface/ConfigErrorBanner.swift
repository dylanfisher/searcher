import AppKit
import Browser

/// The strip across the top of a browser window that shows while the config file has an error:
/// the first error, which names its line, and a button that opens the file. It hides once a
/// good file loads (docs/decisions/0120-config-format.md). The button is a bordered push button,
/// which AppKit draws in its hover, pressed, focused and disabled states
/// (docs/decisions/0110-interaction-states.md).
@MainActor
final class ConfigErrorBanner: NSView {
    let message = NSTextField(wrappingLabelWithString: "")
    let openButton = NSButton(title: SystemCommands.openConfigFile.title, target: nil, action: nil)
    /// Runs when the button is clicked.
    var onOpen: @MainActor () -> Void = {}

    private let icon = NSImageView()
    private let fill = NSBox()

    init() {
        super.init(frame: .zero)
        fill.boxType = .custom
        fill.borderWidth = 0
        fill.cornerRadius = 0
        fill.fillColor = NSColor.systemYellow.withAlphaComponent(0.18)
        icon.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        icon.contentTintColor = .systemYellow
        icon.setContentHuggingPriority(.required, for: .horizontal)
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.maximumNumberOfLines = 2
        message.lineBreakMode = .byTruncatingTail
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        openButton.controlSize = .small
        openButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        openButton.bezelStyle = .push
        openButton.target = self
        openButton.action = #selector(open)
        openButton.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [icon, message, openButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        for view in [fill, row] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: trailingAnchor),
            fill.topAnchor.constraint(equalTo: topAnchor),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Margin.standard),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Margin.standard),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Config file error")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ConfigErrorBanner is built in code")
    }

    /// Shows the first of `errors`, and how many more there are, or hides while there are none.
    /// The button shows only when there is a file to open.
    func show(_ errors: [ConfigError], canOpen: Bool) {
        isHidden = errors.isEmpty
        openButton.isHidden = !canOpen
        guard let first = errors.first else { return }
        var text =
            "Config file \(first). Searcher keeps the settings it had until the file is fixed."
        switch errors.count {
        case 1: break
        case 2: text += " The file has 1 more error."
        default: text += " The file has \(errors.count - 1) more errors."
        }
        message.stringValue = text
        // Every error, one a line, for a pointer that rests on the message.
        message.toolTip = errors.map(\.description).joined(separator: "\n")
    }

    @objc private func open() {
        onOpen()
    }
}
