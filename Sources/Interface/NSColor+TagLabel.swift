import AppKit

extension NSColor {
    /// The color of Finder's color label `label`, 1 to 7, which a tag of that color is drawn in:
    /// the row menu's dots, a row's dots and the preview's pills
    /// (docs/decisions/0124-tags-in-rows-and-preview.md).
    static func tagLabel(_ label: Int) -> NSColor {
        NSWorkspace.shared.fileLabelColors[label]
    }
}
