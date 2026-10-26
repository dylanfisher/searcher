import CoreGraphics

/// The room kept between content and the edge of the view that holds it, the one margin the
/// window's bars and lists share: the path bar's first folder and the operations rows' text sit
/// it from their sides, so they line up, and the operations rows sit it from the panel's top,
/// its bottom and each other.
enum Margin {
    static let standard: CGFloat = 9
}
