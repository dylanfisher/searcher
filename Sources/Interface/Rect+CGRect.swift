import Browser
import CoreGraphics

// Browser keeps its own `Rect` so it stays free of CoreGraphics; these are the only conversions.

extension Rect {
    public init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }
}

extension CGRect {
    public init(_ rect: Rect) {
        self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}
