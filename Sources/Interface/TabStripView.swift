import AppKit

/// The window's row of tabs, drawn as Finder's macOS 26 strip: a fully rounded track across the
/// window, one equal segment per tab, and the selected tab a lighter pill inset in its segment so
/// the track shows around it. A click on a tab reports its index, and a click on its close
/// button, which shows while the mouse is over the tab, reports the index to close. Searcher
/// draws its own strip; AppKit's window tabs are off (docs/decisions/0054-tabs-in-window.md,
/// docs/decisions/0139-finder-tab-strip.md).
@MainActor
final class TabStripView: NSView {
    static let height: CGFloat = 34
    /// What VoiceOver calls the strip.
    static let accessibilityName = "Tabs"
    /// The track's height and the room left and right of it, from Finder's strip.
    static let trackHeight: CGFloat = 28
    static let margin: CGFloat = 6
    static let trackRadius = trackHeight / 2
    /// The gap between the selected tab's pill and its segment's edges, where the track shows.
    static let pillInset: CGFloat = 2
    static let pillRadius = (trackHeight - 2 * pillInset) / 2
    static let closeSide: CGFloat = 16
    /// The close button's distance from its tab's leading edge, 4 points inside the pill.
    static let closeInset = pillInset + 4
    /// The room left and right of a title while the close button is hidden.
    static let titleMargin = pillInset + 8
    /// The colors are the label colors' grays, which the system resolves for light and dark; no
    /// accent color, as Finder's strip has none.
    static let trackColor = NSColor.quaternaryLabelColor
    static let pillColor = NSColor.controlColor
    /// The fills under an unselected tab with the mouse over it, and while it is pressed.
    static let hoverFill = NSColor.quinaryLabelColor
    static let pressedFill = NSColor.quaternaryLabelColor

    private(set) var tabs: [TabButton] = []
    /// Runs with the index of the tab clicked.
    var onSelect: @MainActor (Int) -> Void = { _ in }
    /// Runs with the index of the tab whose close button was clicked.
    var onClose: @MainActor (Int) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(Self.accessibilityName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TabStripView is built in code")
    }

    /// The tabs' titles, left to right.
    var titles: [String] { tabs.map(\.tabTitle) }

    var selectedIndex: Int? { tabs.firstIndex(where: \.isSelectedTab) }

    /// The track the tabs share, centered in the strip.
    var trackRect: NSRect {
        NSRect(
            x: Self.margin, y: (bounds.height - Self.trackHeight) / 2,
            width: bounds.width - 2 * Self.margin, height: Self.trackHeight)
    }

    /// Shows a tab per title with the one at `selected` selected.
    func show(titles: [String], selected: Int) {
        while tabs.count > titles.count {
            tabs.removeLast().removeFromSuperview()
        }
        while tabs.count < titles.count {
            let tab = TabButton()
            tab.target = self
            tab.action = #selector(tabClicked(_:))
            tab.onClose = { [weak self, weak tab] in
                guard let self, let tab, let index = tabs.firstIndex(of: tab) else { return }
                onClose(index)
            }
            tabs.append(tab)
            addSubview(tab)
        }
        for (index, tab) in tabs.enumerated() {
            tab.tabTitle = titles[index]
            tab.isSelectedTab = index == selected
        }
        needsLayout = true
    }

    /// Reports tab `index` selected, as a click on it does.
    func click(_ index: Int) {
        tabClicked(tabs[index])
    }

    override func layout() {
        super.layout()
        let track = trackRect
        let width = track.width / CGFloat(max(tabs.count, 1))
        for (index, tab) in tabs.enumerated() {
            let minX = track.minX + (CGFloat(index) * width).rounded()
            let maxX = track.minX + (CGFloat(index + 1) * width).rounded()
            tab.frame = NSRect(x: minX, y: track.minY, width: maxX - minX, height: track.height)
            tab.updateHover()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.trackColor.setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: Self.trackRadius, yRadius: Self.trackRadius)
            .fill()
    }

    @objc private func tabClicked(_ sender: TabButton) {
        guard let index = tabs.firstIndex(of: sender) else {
            preconditionFailure("a tab that isn't in the strip was clicked")
        }
        onSelect(index)
    }
}

/// One tab in a `TabStripView`: its title centered, a pill while selected, a fill under the
/// mouse and a darker one while pressed when not, and a round close button at its leading end
/// that shows while the mouse is over the tab. Tabs are never disabled: the strip shows only
/// with two tabs or more, and any of them can be selected or closed.
@MainActor
final class TabButton: NSButton {
    let closeButton = HoverButton(side: TabStripView.closeSide, isRound: true)
    /// Runs when the close button, or VoiceOver's Close Tab action, closes the tab.
    var onClose: @MainActor () -> Void = {}

    var tabTitle = "" {
        didSet {
            if tabTitle != oldValue { needsDisplay = true }
        }
    }

    var isSelectedTab = false {
        didSet {
            if isSelectedTab != oldValue { needsDisplay = true }
        }
    }

    /// Whether the mouse is over the tab, its close button included.
    private(set) var isHovered = false {
        didSet {
            closeButton.isHidden = !isHovered
            if isHovered != oldValue { needsDisplay = true }
        }
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    private static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    /// The room the close button takes at the leading end while it shows, kept at the trailing
    /// end too so the title stays centered.
    private static let closeRoom = TabStripView.closeInset + TabStripView.closeSide + 4

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self))
        guard
            let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        else {
            preconditionFailure("there is no system symbol xmark")
        }
        closeButton.image = image
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.setAccessibilityLabel("Close Tab")
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: TabStripView.closeInset),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TabButton is built in code")
    }

    /// The pill's rect, which the selection, the fills and the focus ring take.
    var pillRect: NSRect {
        bounds.insetBy(dx: TabStripView.pillInset, dy: TabStripView.pillInset)
    }

    /// The fill drawn in the pill's shape now, if any.
    var fill: NSColor? {
        if isSelectedTab { return TabStripView.pillColor }
        if isHighlighted { return TabStripView.pressedFill }
        return isHovered ? TabStripView.hoverFill : nil
    }

    var titleColor: NSColor { isSelectedTab ? .labelColor : .secondaryLabelColor }

    /// Where the title is drawn: one line, centered, clear of the close button's room while the
    /// button shows, so narrow tabs keep their titles until the mouse is over them.
    var titleRect: NSRect {
        let height = ceil(Self.font.ascender - Self.font.descender + Self.font.leading)
        let inset = isHovered ? Self.closeRoom : TabStripView.titleMargin
        return NSRect(
            x: inset, y: ((bounds.height - height) / 2).rounded(),
            width: max(bounds.width - 2 * inset, 0), height: height)
    }

    // A tab hidden, with or without its ancestors, or taken out of its window gets no
    // mouseExited, so it would show the hover when shown again.
    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHovered = false
    }

    /// Reads the hover from where the mouse is now. A tab the strip moved, as after a close, gets
    /// no mouseEntered or mouseExited until the mouse moves.
    func updateHover() {
        guard let window, !isHiddenOrHasHiddenAncestor else {
            isHovered = false
            return
        }
        isHovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func draw(_ dirtyRect: NSRect) {
        if let fill {
            NSGraphicsContext.saveGraphicsState()
            if isSelectedTab {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.shadowColor.withAlphaComponent(0.15)
                shadow.shadowOffset = NSSize(width: 0, height: -0.5)
                shadow.shadowBlurRadius = 1.5
                shadow.set()
            }
            fill.setFill()
            pill.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        NSAttributedString(
            string: tabTitle,
            attributes: [
                .font: Self.font, .foregroundColor: titleColor, .paragraphStyle: paragraph,
            ]
        ).draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override var focusRingMaskBounds: NSRect { pillRect }

    override func drawFocusRingMask() {
        pill.fill()
    }

    private var pill: NSBezierPath {
        NSBezierPath(
            roundedRect: pillRect, xRadius: TabStripView.pillRadius,
            yRadius: TabStripView.pillRadius)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }

    override func accessibilityLabel() -> String? { tabTitle }

    override func accessibilityValue() -> Any? { NSNumber(value: isSelectedTab) }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [
            NSAccessibilityCustomAction(name: "Close Tab") { [weak self] in
                MainActor.assumeIsolated { self?.onClose() }
                return true
            }
        ]
    }

    @objc private func closeClicked(_ sender: HoverButton) {
        onClose()
    }
}
