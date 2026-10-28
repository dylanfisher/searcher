import AppKit
import Browser

/// The row menu's tag dots, one per Finder standard tag (`TagDotButton`), with Finder's line
/// under them: "Tags" at rest, and what a click on the dot under the mouse does, "Add Tag
/// “Red”", while one is. A click runs the tag's command on the table the menu was built for
/// and closes the menu. The dots show which tags the selected items have once those are read,
/// off the main actor (docs/decisions/0121-tag-commands.md).
@MainActor
final class TagDotsView: NSView {
    /// The line's text while no dot is under the mouse.
    static let restTitle = "Tags"
    /// The space left of the first dot, so the dots line up with the items' titles.
    static let leading: CGFloat = 18
    static let lineHeight: CGFloat = 16

    let dots: [TagDotButton]
    let line = NSTextField(labelWithString: restTitle)
    private let isEnabled: @MainActor (CommandID) -> Bool
    private let toggle: @MainActor (FinderTag) -> Void
    /// The read of the selection's tags, until it lands.
    private var read: Task<Void, Never>?

    /// `isEnabled` says whether a tag's command can run now; `toggle` runs it.
    init(
        isEnabled: @escaping @MainActor (CommandID) -> Bool,
        toggle: @escaping @MainActor (FinderTag) -> Void
    ) {
        self.isEnabled = isEnabled
        self.toggle = toggle
        dots = FinderTag.all.map(TagDotButton.init)
        let width = Self.leading * 2 + CGFloat(dots.count) * (TagDotButton.side + 2)
        super.init(
            frame: NSRect(x: 0, y: 0, width: width, height: TagDotButton.side + Self.lineHeight + 6)
        )
        for (index, dot) in dots.enumerated() {
            dot.frame.origin = NSPoint(
                x: Self.leading + CGFloat(index) * (TagDotButton.side + 2),
                y: Self.lineHeight + 4)
            dot.target = self
            dot.action = #selector(click(_:))
            dot.onHover = { [weak self] _ in self?.showLine() }
            addSubview(dot)
        }
        line.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        line.textColor = .secondaryLabelColor
        line.frame = NSRect(
            x: Self.leading, y: 2, width: width - Self.leading, height: Self.lineHeight)
        addSubview(line)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(TagCommands.menuTitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TagDotsView is built in code")
    }

    /// Reads the tags of the items at `paths`, and shows on each dot how many have its tag once
    /// they land. A read on a share that stopped answering never lands; the dots stay plain.
    func readTags(of paths: [String]) {
        read?.cancel()
        read = Task { [weak self] in
            let tags = await TagCommands.tags(of: paths)
            guard !Task.isCancelled else { return }
            self?.show(tags)
        }
    }

    /// Whether the selection's tags have landed, for tests.
    var hasTags: Bool { dots.allSatisfy { $0.coverage != nil } }

    /// Shows on each dot how many of the items whose tags are `tags` have its tag.
    func show(_ tags: [[String]]) {
        for dot in dots {
            dot.coverage = dot.finderTag.coverage(in: tags)
        }
        showLine()
    }

    /// Turns each dot on while its command can run, as a menu turns its items on as it opens.
    func validate() {
        for dot in dots {
            dot.isEnabled = isEnabled(TagCommands.command(for: dot.finderTag).id)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow != nil { validate() }
    }

    private func showLine() {
        let hovered = dots.first { $0.isHovered && $0.isEnabled }
        line.stringValue = hovered?.actionTitle ?? Self.restTitle
    }

    @objc private func click(_ sender: TagDotButton) {
        // A press can reach a dot turned off since, as from VoiceOver.
        guard sender.isEnabled else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        toggle(sender.finderTag)
    }
}
