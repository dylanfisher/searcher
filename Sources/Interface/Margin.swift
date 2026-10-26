import CoreGraphics

/// The room kept between content and the edge of the view that holds it, the one margin the
/// window's bars and lists share: the path bar's first folder and the operations rows' text sit
/// it from their sides, so they line up.
enum Margin {
    static let standard: CGFloat = 9
}
