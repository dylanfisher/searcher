import AppKit
import Browser

/// A divider of `PaneLayoutView` as VoiceOver sees it: a splitter whose value is its split's ratio
/// and whose increment and decrement actions move it. `PaneLayoutView` keeps one element per split
/// across layout changes, so VoiceOver stays on the divider it is moving.
///
/// Not main-actor isolated, since AppKit declares `NSAccessibilityElement`'s methods nonisolated.
/// AppKit calls them on the main thread, so only the call back into the view asserts it.
final class DividerAccessibilityElement: NSAccessibilityElement {
    private var divider: Layout.Divider
    private let setRatio: @MainActor (Double) -> Void

    /// `frame` is in `parent`'s coordinates. `setRatio` asks the parent to give the split a new
    /// ratio; the parent clamps it and calls `update` with the result.
    @MainActor init(
        divider: Layout.Divider, frame: NSRect, parent: NSView,
        setRatio: @escaping @MainActor (Double) -> Void
    ) {
        self.divider = divider
        self.setRatio = setRatio
        super.init()
        setAccessibilityParent(parent)
        setAccessibilityFrameInParentSpace(frame)
    }

    func update(divider: Layout.Divider, frame: NSRect) {
        let oldRatio = ratio
        self.divider = divider
        setAccessibilityFrameInParentSpace(frame)
        if ratio != oldRatio {
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    private var position: Double {
        divider.axis == .horizontal ? divider.rect.minX : divider.rect.minY
    }

    private var ratio: Double { divider.ratio(at: position) }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }

    /// The orientation of the divider line, which runs across its split's axis.
    override func accessibilityOrientation() -> NSAccessibilityOrientation {
        divider.axis == .horizontal ? .vertical : .horizontal
    }

    override func accessibilityValue() -> Any? { NSNumber(value: ratio) }

    /// Takes a new ratio, for assistive apps that set the value instead of incrementing it.
    override func setAccessibilityValue(_ value: Any?) {
        guard let number = value as? NSNumber else {
            preconditionFailure("a splitter's value is a ratio, got \(String(describing: value))")
        }
        let ratio = number.doubleValue
        let setRatio = self.setRatio
        MainActor.assumeIsolated { setRatio(ratio) }
    }

    override func accessibilityValueDescription() -> String? {
        ratio.formatted(.percent.precision(.fractionLength(0)))
    }

    override func accessibilityPerformIncrement() -> Bool {
        move(by: TilingCommands.resizeStep)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        move(by: -TilingCommands.resizeStep)
        return true
    }

    private func move(by points: Double) {
        setAccessibilityValue(NSNumber(value: divider.ratio(at: position + points)))
    }
}
