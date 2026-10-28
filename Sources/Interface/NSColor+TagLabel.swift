import AppKit

extension NSColor {
    /// The color of Finder's color label `label`, 1 to 7: the system color Finder draws a tag of
    /// that color in. A dot's rim is drawn in it and a preview pill is filled with it
    /// (docs/decisions/0127-tag-colors-and-pill-widths.md).
    static func tagLabel(_ label: Int) -> NSColor {
        precondition(tagLabels.indices.contains(label - 1), "No tag color has label \(label)")
        return tagLabels[label - 1]
    }

    /// What a dot of label `label`'s color is filled with, the row's and the row menu's, as
    /// Finder fills them: the tag's color lightened toward white by `tagDotLightening`, in each
    /// appearance.
    static func tagLabelDot(_ label: Int) -> NSColor {
        precondition(tagLabels.indices.contains(label - 1), "No tag color has label \(label)")
        return tagLabelDots[label - 1]
    }

    /// How far a dot's fill is from its tag's color toward white: Finder's dots measure as their
    /// system color lightened a fifth of the way, in Display P3.
    static let tagDotLightening: CGFloat = 0.2

    /// The colors of labels 1 to 7: Gray, Green, Purple, Blue, Yellow, Red and Orange, the order
    /// of `NSWorkspace.fileLabels`.
    private static let tagLabels: [NSColor] = [
        .systemGray, .systemGreen, .systemPurple, .systemBlue, .systemYellow, .systemRed,
        .systemOrange,
    ]

    /// The dots' fills of labels 1 to 7, made once, so each label's is one color.
    private static let tagLabelDots: [NSColor] = tagLabels.map { color in
        // The provider runs with the appearance it is asked for current, so the system color
        // resolves to that appearance's.
        NSColor(name: nil) { _ in
            guard let resolved = color.usingColorSpace(.displayP3) else {
                preconditionFailure("\(color) has no Display P3 form")
            }
            func lightened(_ component: CGFloat) -> CGFloat {
                component + tagDotLightening * (1 - component)
            }
            return NSColor(
                displayP3Red: lightened(resolved.redComponent),
                green: lightened(resolved.greenComponent),
                blue: lightened(resolved.blueComponent), alpha: resolved.alphaComponent)
        }
    }
}
