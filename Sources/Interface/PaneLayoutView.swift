import AppKit
import Browser

/// Shows a `Layout`: sets each pane view's frame from `frames(in:)`, and draws, drags, sets cursors
/// for and exposes to accessibility the dividers from `dividers(in:)`. One view setting plain
/// frames, since nested `NSSplitView`s drift from the model's ratios (0007-layout-tree.md).
@MainActor
public class PaneLayoutView: NSView {
    /// The drag area and cursor rect reach this far past each side of a divider, since the drawn
    /// divider is only `Layout.dividerThickness` wide.
    static let dragMargin = 3.0

    public var layout: Layout {
        didSet {
            precondition(Set(layout.panes) == Set(paneViews.keys), "every pane needs one view")
            applyLayout()
        }
    }

    private var paneViews: [PaneID: NSView]
    /// Gives a split a new ratio for a divider drag or VoiceOver, and returns the layout to show.
    /// A window replaces it to set the ratio on the tab that owns the layout.
    var applyRatio:
        @MainActor (_ layout: Layout, _ ratio: Double, _ path: [LayoutNode.Child], _ bounds: Rect)
            -> Layout = { layout, ratio, path, bounds in
                var layout = layout
                layout.setRatio(ratio, at: path, in: bounds)
                return layout
            }
    /// `layout.dividers(in:)` for the current bounds.
    private var dividers: [Layout.Divider] = []
    private var dividerElements: [[LayoutNode.Child]: DividerAccessibilityElement] = [:]
    /// The divider being dragged, and how far from its leading edge it was grabbed.
    private var drag: (divider: Layout.Divider, offset: Double)?

    /// `paneViews` holds one view for each pane in `layout`.
    public init(layout: Layout, paneViews: [PaneID: NSView]) {
        precondition(Set(layout.panes) == Set(paneViews.keys), "every pane needs one view")
        self.layout = layout
        self.paneViews = paneViews
        super.init(frame: .zero)
        for pane in layout.panes {
            addSubview(paneView(for: pane))
        }
        setAccessibilityRole(.splitGroup)
        setAccessibilityElement(true)
        applyLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaneLayoutView is built in code")
    }

    /// Shows `layout` with `paneViews`, one view for each of its panes: adds the views it didn't
    /// have and removes the ones it no longer has.
    public func show(_ layout: Layout, paneViews: [PaneID: NSView]) {
        precondition(Set(layout.panes) == Set(paneViews.keys), "every pane needs one view")
        guard layout != self.layout || paneViews != self.paneViews else { return }
        for (pane, view) in self.paneViews where paneViews[pane] !== view {
            view.removeFromSuperview()
        }
        for (pane, view) in paneViews where self.paneViews[pane] !== view {
            addSubview(view)
        }
        self.paneViews = paneViews
        self.layout = layout
    }

    func paneView(for pane: PaneID) -> NSView {
        guard let view = paneViews[pane] else { preconditionFailure("no view for pane \(pane)") }
        return view
    }

    /// Layout coordinates grow downward.
    public override var isFlipped: Bool { true }

    // MARK: Layout

    /// Sets the pane frames here instead of in `layout()`, so they follow a frame change at once
    /// without waiting for a layout pass.
    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        applyLayout()
    }

    private func applyLayout() {
        let bounds = Rect(self.bounds)
        let frames = layout.frames(in: bounds)
        for (pane, view) in paneViews {
            if let frame = frames[pane] {
                view.frame = CGRect(frame)
                view.isHidden = false
            } else {
                // Covered by the zoomed pane.
                view.isHidden = true
            }
        }
        dividers = layout.dividers(in: bounds)
        updateDividerElements()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func setRatio(_ ratio: Double, at path: [LayoutNode.Child]) {
        layout = applyRatio(layout, ratio, path, Rect(bounds))
    }

    // MARK: Dividers

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        for divider in dividers {
            CGRect(divider.rect).intersection(dirtyRect).fill()
        }
    }

    private func dragRect(of divider: Layout.Divider) -> NSRect {
        let rect = CGRect(divider.rect)
        return divider.axis == .horizontal
            ? rect.insetBy(dx: -Self.dragMargin, dy: 0)
            : rect.insetBy(dx: 0, dy: -Self.dragMargin)
    }

    private func divider(at point: NSPoint) -> Layout.Divider? {
        dividers.first { dragRect(of: $0).contains(point) }
    }

    /// The coordinate along a split's axis, which `Layout.Divider.ratio(at:)` takes.
    private func position(of point: NSPoint, along axis: Axis) -> Double {
        axis == .horizontal ? point.x : point.y
    }

    public override func resetCursorRects() {
        for divider in dividers {
            let cursor: NSCursor = divider.axis == .horizontal ? .resizeLeftRight : .resizeUpDown
            addCursorRect(dragRect(of: divider), cursor: cursor)
        }
    }

    /// Takes clicks in a divider's drag area, which overlaps the panes beside it.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        if !isHidden, divider(at: convert(point, from: superview)) != nil {
            return self
        }
        return super.hitTest(point)
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let divider = divider(at: point) else {
            super.mouseDown(with: event)
            return
        }
        let edge = position(of: CGRect(divider.rect).origin, along: divider.axis)
        drag = (divider, position(of: point, along: divider.axis) - edge)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let drag else {
            super.mouseDragged(with: event)
            return
        }
        // Moving a divider leaves its split's rect alone, so the divider from the press still
        // converts positions to ratios.
        let point = convert(event.locationInWindow, from: nil)
        let edge = position(of: point, along: drag.divider.axis) - drag.offset
        setRatio(drag.divider.ratio(at: edge), at: drag.divider.path)
    }

    public override func mouseUp(with event: NSEvent) {
        guard drag != nil else {
            super.mouseUp(with: event)
            return
        }
        drag = nil
    }

    // MARK: Accessibility

    public override func accessibilityChildren() -> [Any]? {
        let elements: [Any] = dividers.compactMap { dividerElements[$0.path] }
        return (super.accessibilityChildren() ?? []) + elements
    }

    /// Keeps the element of each split that still exists, so VoiceOver's focus survives a move.
    private func updateDividerElements() {
        var elements: [[LayoutNode.Child]: DividerAccessibilityElement] = [:]
        for divider in dividers {
            let frame = dragRect(of: divider)
            if let element = dividerElements[divider.path] {
                element.update(divider: divider, frame: frame)
                elements[divider.path] = element
            } else {
                let path = divider.path
                elements[path] = DividerAccessibilityElement(
                    divider: divider, frame: frame, parent: self
                ) { [weak self] ratio in
                    self?.setRatio(ratio, at: path)
                }
            }
        }
        dividerElements = elements
    }
}
