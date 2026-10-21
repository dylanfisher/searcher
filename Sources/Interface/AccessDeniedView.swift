import AppKit
import Browser

/// What a pane shows for a folder the system won't let the app list: why, and a button that opens
/// the Full Disk Access list in System Settings.
///
/// It sits over the pane's table rather than taking its place, so the table keeps keyboard focus
/// and Cmd-↑ still goes back from the denied folder.
@MainActor
final class AccessDeniedView: NSView {
    /// The Full Disk Access pane of Privacy & Security.
    static let fullDiskAccessSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    static let explanation =
        "macOS lets Searcher read this folder only with Full Disk Access. Turn on Searcher in the Full Disk Access list, then reopen Searcher."
    static let buttonTitle = "Open Full Disk Access Settings"

    static func title(folderName: String) -> String {
        "Searcher can’t read “\(folderName)”"
    }

    let titleLabel = NSTextField(labelWithString: "")
    let explanationLabel = NSTextField(wrappingLabelWithString: explanation)
    let openSettingsButton = NSButton(title: buttonTitle, target: nil, action: nil)

    /// The denied folder's name, shown in the title.
    var folderName = "" {
        didSet {
            titleLabel.stringValue = Self.title(folderName: folderName)
            setAccessibilityLabel(titleLabel.stringValue)
        }
    }

    private let systemActions: any SystemActions

    init(systemActions: any SystemActions) {
        self.systemActions = systemActions
        super.init(frame: .zero)
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        // Below the pane's preferred width for this view, so a long name truncates instead of
        // widening the view.
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        explanationLabel.alignment = .center
        explanationLabel.textColor = .secondaryLabelColor
        openSettingsButton.target = self
        openSettingsButton.action = #selector(openSettings)

        let stack = NSStackView(views: [titleLabel, explanationLabel, openSettingsButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(16, after: explanationLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            explanationLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AccessDeniedView is built in code")
    }

    @objc private func openSettings() {
        systemActions.openURL(Self.fullDiskAccessSettings)
    }
}
