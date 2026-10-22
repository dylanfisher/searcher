import AppKit

/// The window's row of tabs: one segment per tab, titled, with the selected tab's segment
/// selected. A click on a segment reports its index. Searcher draws its own strip; AppKit's
/// window tabs are off (docs/decisions/0054-tabs-in-window.md).
@MainActor
final class TabStripView: NSView {
    static let height: CGFloat = 28
    /// What VoiceOver calls the strip.
    static let accessibilityName = "Tabs"

    let control = NSSegmentedControl()
    /// Runs with the index of the segment clicked.
    var onSelect: @MainActor (Int) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.target = self
        control.action = #selector(segmentClicked(_:))
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(Self.accessibilityName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TabStripView is built in code")
    }

    /// The segments' titles, left to right.
    var titles: [String] {
        (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" }
    }

    var selectedIndex: Int { control.selectedSegment }

    /// Shows a segment per title with the one at `selected` selected.
    func show(titles: [String], selected: Int) {
        if titles != self.titles {
            control.segmentCount = titles.count
            for (index, title) in titles.enumerated() {
                control.setLabel(title, forSegment: index)
            }
        }
        control.selectedSegment = selected
    }

    /// Selects segment `index` and reports it, as a click on it does.
    func click(_ index: Int) {
        control.selectedSegment = index
        segmentClicked(control)
    }

    @objc private func segmentClicked(_ sender: NSSegmentedControl) {
        onSelect(sender.selectedSegment)
    }
}
