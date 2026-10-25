import AppKit

/// A pane's root view, which draws the ring around the pane with the keys as its layer's border.
/// A border's `CGColor` is fixed when it is set, where an `NSColor` follows the appearance, so
/// the view resolves the color again for its own appearance whenever that changes.
@MainActor
final class PaneContainerView: NSView {
    static let focusRingWidth = 2.0

    var showsFocusRing = false {
        didSet {
            guard showsFocusRing != oldValue else { return }
            wantsLayer = true
            layer?.borderWidth = showsFocusRing ? Self.focusRingWidth : 0
            resolveRingColor()
        }
    }

    /// Runs when a press reaches the container: a press on something in the pane that takes no
    /// press itself, such as the preview's empty space, the gap between columns or the path bar.
    /// The pane takes the keys, as a press on a row gives them.
    var onPress: @MainActor () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        onPress()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveRingColor()
    }

    private func resolveRingColor() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
        }
    }
}
