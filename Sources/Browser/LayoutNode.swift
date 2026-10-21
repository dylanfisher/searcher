/// A node of the layout's binary split tree.
public indirect enum LayoutNode: Codable, Equatable, Sendable {
    /// One child of a split. A divider's path lists these from the root down to its split.
    public enum Child: String, Codable, Sendable {
        case first, second
    }

    case pane(PaneID)
    /// `first` is left of or above `second`. `ratio` is `first`'s share of the space left after the
    /// divider, strictly between 0 and 1.
    case split(axis: Axis, ratio: Double, first: LayoutNode, second: LayoutNode)

    /// Every pane in the subtree, left to right and top to bottom.
    public var panes: [PaneID] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, let first, let second): first.panes + second.panes
        }
    }
}
